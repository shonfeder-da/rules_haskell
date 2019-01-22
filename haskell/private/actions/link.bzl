"""Actions for linking object code produced by compilation"""

load(":private/packages.bzl", "expose_packages")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":private/path_utils.bzl", "get_lib_name", "is_shared_library", "is_static_library")
load(":private/pkg_id.bzl", "pkg_id")
load(":private/set.bzl", "set")
load(":private/list.bzl", "list")
load(":private/providers.bzl", "external_libraries_get_mangled")

# tests in /tests/unit_tests/BUILD
def parent_dir_path(path):
    """Returns the path of the parent directory.
    For a relative path with just a file, "." is returned.
    The path is not normalized.

    foo => .
    foo/ => foo
    foo/bar => foo
    foo/bar/baz => foo/bar
    foo/../bar => foo/..

    Args:
      a path string

    Returns:
      A path list of the form `["foo", "bar"]`
    """
    path_dir = paths.dirname(path)

    # dirname returns "" if there is no parent directory
    # In that case we return the identity path, which is ".".
    if path_dir == "":
        return ["."]
    else:
        return path_dir.split("/")

def __check_dots(target, path):
    # there’s still (non-leading) .. in split
    if ".." in path:
        fail("the short_path of target {} (which is {}) contains more dots than loading `../`. We can’t handle that.".format(
            target,
            target.short_path,
        ))

# skylark doesn’t allow nested defs, which is a mystery.
def _get_target_parent_dir(target):
    """get the parent dir and handle leading short_path dots,
    which signify that the target is in an external repository.

    Args:
      target: a target, .short_path is used
    Returns:
      (is_external, parent_dir)
      `is_external`: Bool whether the path points to an external repository
      `parent_dir`: The parent directory, either up to the runfiles toplel,
                    up to the external repository toplevel.
    """

    parent_dir = parent_dir_path(target.short_path)

    if parent_dir[0] == "..":
        __check_dots(target, parent_dir[1:])
        return (True, parent_dir[1:])
    else:
        __check_dots(target, parent_dir)
        return (False, parent_dir)

# tests in /tests/unit_tests/BUILD
def create_rpath_entry(binary, dependency, keep_filename, prefix = ""):
    """Return a (relative) path that points from `binary` to `dependecy`
    while not leaving the current bazel runpath, taking into account weird
    corner cases of `.short_path` concerning external repositories.
    The resulting entry should be able to be inserted into rpath or similar.

    runpath/foo/a.so to runfile/bar/b.so => ../bar
    with `keep_filename=True`:
    runpath/foo/a.so to runfile/bar/b.so => ../bar/b.so
    with `prefix="$ORIGIN"`:
    runpath/foo/a.so to runfile/bar/b.so => $ORIGIN/../bar/b.so

    Args:
      binary: target of current binary
      dependency: target of dependency to relatively point to
      prefix: string path prefix to add before the relative path
      keep_filename: whether to point to the filename or its parent dir

    Returns:
      relative path string
    """
    (bin_is_external, bin_parent_dir) = _get_target_parent_dir(binary)
    (dep_is_external, dep_parent_dir) = _get_target_parent_dir(dependency)

    # backup through parent directories of the binary
    bin_backup = [".."] * len(bin_parent_dir)

    # external repositories live in `target.runfiles/external`,
    # while the internal repository lives in `target.runfiles`.
    # The `.short_path`s of external repositories are strange,
    # they start with `../`, but you cannot just append that in
    # order to find the correct runpath. Instead you have to use
    # the following logic to construct the correct runpaths:
    if bin_is_external:
        if dep_is_external:
            # stay in `external`
            path_segments = bin_backup
        else:
            # backup out of `external`
            path_segments = [".."] + bin_backup
    elif dep_is_external:
        # go into `external`
        path_segments = bin_backup + ["external"]
    else:
        # no special external traversal
        path_segments = bin_backup

    # then add the parent dir to our dependency
    path_segments.extend(dep_parent_dir)

    # and optionally add the filename
    if keep_filename:
        path_segments.append(
            paths.basename(dependency.short_path),
        )

    # normalize for good measure and create the final path
    path = paths.normalize("/".join(path_segments))

    # and add the prefix if applicable
    if prefix == "":
        return path
    else:
        return prefix + "/" + path

def _fix_darwin_linker_paths(hs, inp, out, external_libraries):
    """Postprocess a macOS binary to make shared library references relative.

    On macOS, in order to simulate the linker "rpath" behavior and make the
    binary load shared libraries from relative paths, (or dynamic libraries
    load other libraries) we need to postprocess it with install_name_tool.
    (This is what the Bazel-provided `cc_wrapper.sh` does for cc rules.)
    For details: https://blogs.oracle.com/dipol/entry/dynamic_libraries_rpath_and_mac

    Args:
      hs: Haskell context.
      inp: An input file.
      out: An output file.
      external_libraries: HaskellBuildInfo external_libraries to make relative.
    """
    hs.actions.run_shell(
        inputs = [inp],
        outputs = [out],
        mnemonic = "HaskellFixupLoaderPath",
        progress_message = "Fixing install paths for {0}".format(out.basename),
        command = " &&\n    ".join(
            [
                "cp {} {}".format(inp.path, out.path),
                "chmod +w {}".format(out.path),
                # Patch the "install name" or "library identifaction name".
                # The "install name" informs targets that link against `out`
                # where `out` can be found during runtime. Here we update this
                # "install name" to the new filename of the fixed binary.
                # Refer to the Oracle blog post linked above for details.
                "/usr/bin/install_name_tool -id @rpath/{} {}".format(
                    out.basename,
                    out.path,
                ),
            ] +
            [
                # Make rpaths for external library dependencies relative to the
                # binary's installation path, rather than the working directory
                # at execution time.
                "/usr/bin/install_name_tool -change {} {} {}".format(
                    f.lib.path,
                    create_rpath_entry(
                        out,
                        f.lib,
                        keep_filename = True,
                        prefix = "@loader_path",
                    ),
                    out.path,
                )
                # we use the unmangled lib (f.lib) for this instead of a mangled lib name
                for f in set.to_list(external_libraries)
            ],
        ),
    )

def _create_objects_dir_manifest(hs, objects_dir, dynamic, with_profiling):
    suffix = ".dynamic.manifest" if dynamic else ".static.manifest"
    objects_dir_manifest = hs.actions.declare_file(
        objects_dir.basename + suffix,
        sibling = objects_dir,
    )

    if with_profiling:
        ext = "p_o"
    elif dynamic:
        ext = "dyn_o"
    else:
        ext = "o"
    hs.actions.run_shell(
        inputs = [objects_dir],
        outputs = [objects_dir_manifest],
        command = """
        find {dir} -name '*.{ext}' > {out}
        """.format(
            dir = objects_dir.path,
            ext = ext,
            out = objects_dir_manifest.path,
        ),
        use_default_shell_env = True,
    )

    return objects_dir_manifest

def link_binary(
        hs,
        cc,
        dep_info,
        extra_srcs,
        compiler_flags,
        objects_dir,
        dynamic,
        with_profiling,
        version):
    """Link Haskell binary from static object files.

    Returns:
      File: produced executable
    """

    exe_name = hs.name + (".exe" if hs.toolchain.is_windows else "")
    executable = hs.actions.declare_file(exe_name)
    if not hs.toolchain.is_darwin:
        compile_output = executable
    else:
        compile_output = hs.actions.declare_file(hs.name + ".temp")
        _fix_darwin_linker_paths(
            hs,
            compile_output,
            executable,
            dep_info.external_libraries,
        )

    args = hs.actions.args()
    args.add(["-optl" + f for f in cc.linker_flags])
    if with_profiling:
        args.add("-prof")
    args.add(hs.toolchain.compiler_flags)
    args.add(compiler_flags)

    # By default, GHC will produce mostly-static binaries, i.e. in which all
    # Haskell code is statically linked and foreign libraries and system
    # dependencies are dynamically linked. If linkstatic is false, i.e. the user
    # has requested fully dynamic linking, we must therefore add flags to make
    # sure that GHC dynamically links Haskell code too. The one exception to
    # this is when we are compiling for profiling, which currently does not play
    # nicely with dynamic linking.
    if dynamic:
        if with_profiling:
            print("WARNING: dynamic linking and profiling don't mix. Omitting -dynamic.\nSee https://ghc.haskell.org/trac/ghc/ticket/15394")
        else:
            args.add(["-pie", "-dynamic"])

    # When compiling with `-threaded`, GHC needs to link against
    # the pthread library when linking against static archives (.a).
    # We assume it’s not a problem to pass it for other cases,
    # so we just default to passing it.
    args.add("-optl-pthread")

    args.add(["-o", compile_output.path])

    # De-duplicate optl calls while preserving ordering: we want last
    # invocation of an object to remain last. That is `-optl foo -optl
    # bar -optl foo` becomes `-optl bar -optl foo`. Do this by counting
    # number of occurrences. That way we only build dict and add to args
    # directly rather than doing multiple reversals with temporary
    # lists.

    args.add(expose_packages(
        dep_info,
        lib_info = None,
        use_direct = True,
        use_my_pkg_id = None,
        custom_package_caches = None,
        version = version,
    ))

    _add_external_libraries(args, dep_info.external_libraries)

    # By default GHC will link foreign library dependencies dynamically.
    # If linkstatic is true we hide dynamic libraries from the linking step if
    # static libraries are available instead, in order to link as many
    # dependencies statically as possible.
    # This is to follow the "mostly static" semantics of Bazel's CC rules.
    (static_libs, dynamic_libs) = _separate_static_and_dynamic_libraries(
        dep_info.external_libraries,
        dynamic,
    )

    solibs = set.union(dynamic_libs, dep_info.dynamic_libraries)

    # XXX: Suppress a warning that Clang prints due to GHC automatically passing
    # "-pie" or "-no-pie" to the C compiler.
    # This is linked to https://ghc.haskell.org/trac/ghc/ticket/15319
    args.add([
        "-optc-Wno-unused-command-line-argument",
        "-optl-Wno-unused-command-line-argument",
    ])

    if hs.toolchain.is_darwin:
        args.add(["-optl-Wl,-headerpad_max_install_names"])

        # Nixpkgs commit 3513034208a introduces -liconv in NIX_LDFLAGS on
        # Darwin. We don't currently handle NIX_LDFLAGS in any special
        # way, so a hack is to simply do what NIX_LDFLAGS is telling us we
        # should do always when using a toolchain from Nixpkgs.
        # TODO remove this gross hack.
        args.add("-liconv")

    for rpath in set.to_list(_infer_rpaths(hs.toolchain.is_darwin, executable, solibs)):
        args.add(["-optl-Wl,-rpath," + rpath])

    objects_dir_manifest = _create_objects_dir_manifest(
        hs,
        objects_dir,
        dynamic = dynamic,
        with_profiling = with_profiling,
    )
    hs.toolchain.actions.run_ghc(
        hs,
        cc,
        inputs = depset(transitive = [
            depset(extra_srcs),
            set.to_depset(dep_info.package_caches),
            set.to_depset(dep_info.dynamic_libraries),
            depset(dep_info.static_libraries),
            depset(dep_info.static_libraries_prof),
            depset([objects_dir]),
            set.to_depset(static_libs),
            set.to_depset(dynamic_libs),
        ]),
        outputs = [compile_output],
        mnemonic = "HaskellLinkBinary",
        arguments = args,
        params_file = objects_dir_manifest,
    )

    return executable

def __mangled_lib_name(ext_lib):
    return get_lib_name(ext_lib.mangled_lib)

def _add_external_libraries(args, ext_libs):
    """Add options to `args` that allow us to link to `ext_libs`.

    Args:
      args: Args object.
      ext_libs: external_libraries from HaskellBuildInfo
    """

    # Normally, GHC adds `-Wl,-rpath,<dir>` to the linker for every
    # `<dir>` that is added with `-L` (`-dynload=sysdep`).
    # These paths are of no value to bazel, because the `lib.path`
    # dirs we add below are only valid at link-time. We add the
    # correct load-time paths (`lib.short_path`) below manually,
    # and use `-dynload=deploy` so GHC doesn’t add any.
    # See https://downloads.haskell.org/~ghc/7.6.1/docs/html/users_guide/using-shared-libs.html#finding-shared-libs-unix
    # The difference between link-time and load-time comes from
    # bazel sandboxing the runtime.
    # (see: bazel runfiles).
    args.add("-dynload=deploy")

    # Deduplicate the list of ext_libs based on their mangled
    # library name (file name stripped of lib prefix and endings).
    # This keeps the command lines short, e.g. when a C library
    # like `liblz4.so` appears in multiple dependencies.
    deduped = list.dedup_on(set.to_list(ext_libs), __mangled_lib_name)

    for ext_lib in deduped:
        lib = ext_lib.mangled_lib
        args.add([
            "-L{0}".format(
                paths.dirname(lib.path),
            ),
            "-l{0}".format(
                # technically this is the second call to get_lib_name,
                #  but the added clarity makes up for it.
                get_lib_name(lib),
            ),
        ])

def _separate_static_and_dynamic_libraries(ext_libs, dynamic):
    """Separate static and dynamic libraries while avoiding duplicates.

    Args:
      ext_libs: external_libraries from HaskellBuildInfo
      dynamic: Whether we're linking dynamically or statically.

    Returns:
      A tuple (static_libs, dynamic_libs) where each library dependency occurs
      only once in either static_libs or dynamic_libs. In cases where both
      versions are available, take preference according to the dynamic argument.
    """
    seen_libs = set.empty()
    static_libs = set.empty()
    dynamic_libs = set.empty()

    if dynamic:
        # Prefer dynamic libraries over static libraries.
        preference = is_shared_library
        preferred = dynamic_libs
        remaining = static_libs
    else:
        # Prefer static libraries over dynamic libraries.
        preference = is_static_library
        preferred = static_libs
        remaining = dynamic_libs

    # Find the preferred libraries
    for ext_lib in set.to_list(ext_libs):
        lib = ext_lib.mangled_lib
        lib_name = get_lib_name(lib)
        if preference(lib) and not set.is_member(seen_libs, lib_name):
            set.mutable_insert(seen_libs, lib_name)
            set.mutable_insert(preferred, lib)

    # Find the remaining libraries
    for ext_lib in set.to_list(ext_libs):
        lib = ext_lib.mangled_lib
        lib_name = get_lib_name(lib)
        if not preference(lib) and not set.is_member(seen_libs, lib_name):
            set.mutable_insert(seen_libs, lib_name)
            set.mutable_insert(remaining, lib)

    return (static_libs, dynamic_libs)

def _infer_rpaths(is_darwin, target, solibs):
    """Return set of RPATH values to be added to target so it can find all
    solibs

    The resulting paths look like:
    $ORIGIN/../../path/to/solib/dir
    This means: "go upwards to your runfiles directory, then descend into
    the parent folder of the solib".

    Args:
      is_darwin: Whether we're compiling on and for Darwin.
      target: File, executable or library we're linking.
      solibs: A set of Files, shared objects that the target needs.

    Returns:
      Set of strings: rpaths to add to target.
    """
    r = set.empty()

    if is_darwin:
        prefix = "@loader_path"
    else:
        prefix = "$ORIGIN"

    for solib in set.to_list(solibs):
        rpath = create_rpath_entry(
            target,
            solib,
            keep_filename = False,
            prefix = prefix,
        )
        set.mutable_insert(r, rpath)

    return r

def _so_extension(hs):
    """Returns the extension for shared libraries.

    Args:
      ctx: Rule context.

    Returns:
      string of extension.
    """
    return "dylib" if hs.toolchain.is_darwin else "so"

def link_library_static(hs, cc, dep_info, objects_dir, my_pkg_id, with_profiling):
    """Link a static library for the package using given object files.

    Returns:
      File: Produced static library.
    """
    static_library = hs.actions.declare_file(
        "lib{0}.a".format(pkg_id.library_name(hs, my_pkg_id, prof_suffix = with_profiling)),
    )
    objects_dir_manifest = _create_objects_dir_manifest(
        hs,
        objects_dir,
        dynamic = False,
        with_profiling = with_profiling,
    )
    args = hs.actions.args()
    inputs = [objects_dir, objects_dir_manifest] + cc.files

    if hs.toolchain.is_darwin:
        # On Darwin, ar doesn't support params files.
        args.add([
            static_library,
            objects_dir_manifest.path,
        ])

        # TODO Get ar location from the CC toolchain. This is
        # complicated by the fact that the CC toolchain does not
        # always use ar, and libtool has an entirely different CLI.
        # See https://github.com/bazelbuild/bazel/issues/5127
        hs.actions.run_shell(
            inputs = inputs,
            outputs = [static_library],
            mnemonic = "HaskellLinkStaticLibrary",
            command = "{ar} qc $1 $(< $2)".format(ar = cc.tools.ar),
            arguments = [args],

            # Use the default macosx toolchain
            env = {"SDKROOT": "macosx"},
        )
    else:
        args.add([
            "qc",
            static_library,
            "@" + objects_dir_manifest.path,
        ])
        hs.actions.run(
            inputs = inputs,
            outputs = [static_library],
            mnemonic = "HaskellLinkStaticLibrary",
            executable = cc.tools.ar,
            arguments = [args],
        )

    return static_library

def link_library_dynamic(hs, cc, dep_info, extra_srcs, objects_dir, my_pkg_id):
    """Link a dynamic library for the package using given object files.

    Returns:
      File: Produced dynamic library.
    """
    dynamic_library = hs.actions.declare_file(
        "lib{0}-ghc{1}.{2}".format(
            pkg_id.library_name(hs, my_pkg_id),
            hs.toolchain.version,
            _so_extension(hs),
        ),
    )

    args = hs.actions.args()
    args.add(["-optl" + f for f in cc.linker_flags])
    args.add(["-shared", "-dynamic"])

    # Work around macOS linker limits.  This fix has landed in GHC HEAD, but is
    # not yet in a release; plus, we still want to support older versions of
    # GHC.  For details, see: https://phabricator.haskell.org/D4714
    if hs.toolchain.is_darwin:
        args.add(["-optl-Wl,-dead_strip_dylibs"])

    args.add(expose_packages(
        dep_info,
        lib_info = None,
        use_direct = True,
        use_my_pkg_id = None,
        custom_package_caches = None,
        version = my_pkg_id.version if my_pkg_id else None,
    ))

    _add_external_libraries(args, dep_info.external_libraries)

    solibs = set.union(
        set.map(dep_info.external_libraries, external_libraries_get_mangled),
        dep_info.dynamic_libraries,
    )

    if hs.toolchain.is_darwin:
        dynamic_library_tmp = hs.actions.declare_file(dynamic_library.basename + ".temp")
        _fix_darwin_linker_paths(
            hs,
            dynamic_library_tmp,
            dynamic_library,
            dep_info.external_libraries,
        )
        args.add(["-optl-Wl,-headerpad_max_install_names"])
    else:
        dynamic_library_tmp = dynamic_library

    for rpath in set.to_list(_infer_rpaths(hs.toolchain.is_darwin, dynamic_library_tmp, solibs)):
        args.add(["-optl-Wl,-rpath," + rpath])

    args.add(["-o", dynamic_library_tmp.path])

    # Profiling not supported for dynamic libraries.
    objects_dir_manifest = _create_objects_dir_manifest(
        hs,
        objects_dir,
        dynamic = True,
        with_profiling = False,
    )

    hs.toolchain.actions.run_ghc(
        hs,
        cc,
        inputs = depset([objects_dir], transitive = [
            depset(extra_srcs),
            set.to_depset(dep_info.package_caches),
            set.to_depset(dep_info.dynamic_libraries),
            depset([e.mangled_lib for e in set.to_list(dep_info.external_libraries)]),
        ]),
        outputs = [dynamic_library_tmp],
        mnemonic = "HaskellLinkDynamicLibrary",
        arguments = args,
        params_file = objects_dir_manifest,
    )

    return dynamic_library
