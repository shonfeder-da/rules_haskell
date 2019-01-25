"""Interop with cc_* rules

These rules are temporary and will be deprecated in the future.
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load(":private/path_utils.bzl", "ln")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":private/set.bzl", "set")
load(
    "@io_tweag_rules_haskell//haskell:private/providers.bzl",
    "CcSkylarkApiProviderHacked",
    "HaskellBinaryInfo",
    "HaskellBuildInfo",
)

CcInteropInfo = provider(
    doc = "Information needed for interop with cc rules.",
    fields = {
        "tools": "Tools from the CC toolchain",
        # See the following for why this is needed:
        # https://stackoverflow.com/questions/52769846/custom-c-rule-with-the-cc-common-api
        "files": "Files for all tools (input to any action that uses tools)",
        "hdrs": "CC headers",
        "cpp_flags": "Preprocessor flags",
        "compiler_flags": "Flags for compilation",
        "linker_flags": "Flags to forward to the linker",
        "include_args": "Extra include dirs",
    },
)

def cc_interop_info(ctx):
    """Gather information from any CC dependencies.

    *Internal function - do not use.*

    Args:
      ctx: Rule context.

    Returns:
      CcInteropInfo: Information needed for CC interop.
    """
    hdrs = depset()

    # XXX There's gotta be a better way to test the presence of
    # CcSkylarkApiProvider.
    ccs = [dep.cc for dep in ctx.attr.deps if hasattr(dep, "cc")]

    hdrs = depset(transitive = [cc.transitive_headers for cc in ccs])

    hdrs = depset(transitive = [hdrs] + [
        # XXX cc_import doesn't produce a cc field, so we emulate it with a
        # custom provider.
        dep[CcSkylarkApiProviderHacked].transitive_headers
        for dep in ctx.attr.deps
        if CcSkylarkApiProviderHacked in dep
    ])

    include_directories = set.to_list(set.from_list(
        [f for cc in ccs for f in cc.include_directories] +
        [
            f
            for dep in ctx.attr.deps
            if CcSkylarkApiProviderHacked in dep
            for f in dep[CcSkylarkApiProviderHacked].include_directories
        ],
    ))
    quote_include_directories = set.to_list(set.from_list(
        [f for cc in ccs for f in cc.quote_include_directories],
    ))
    system_include_directories = set.to_list(set.from_list(
        [f for cc in ccs for f in cc.system_include_directories],
    ))

    cpp_flags = (
        ["-D" + define for cc in ccs for define in cc.defines] +
        [
            f
            for include in quote_include_directories
            for f in ["-iquote", include]
        ] +
        [
            f
            for include in system_include_directories
            for f in ["-isystem", include]
        ]
    )

    include_args = ["-I" + include for include in include_directories]

    # XXX Workaround https://github.com/bazelbuild/bazel/issues/6874.
    # Should be find_cpp_toolchain() instead.
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
    )
    compiler_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
        variables = compile_variables,
    )
    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        is_linking_dynamic_library = False,
        is_static_linking_mode = True,
    )
    linker_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
        variables = link_variables,
    )

    # XXX Workaround https://github.com/bazelbuild/bazel/issues/6876.
    linker_flags = [flag for flag in linker_flags if flag not in ["-shared"]]

    tools = {
        "ar": cc_toolchain.ar_executable(),
        "cc": cc_toolchain.compiler_executable(),
        "ld": cc_toolchain.ld_executable(),
        "cpp": cc_toolchain.preprocessor_executable(),
        "nm": cc_toolchain.nm_executable(),
    }

    # If running on darwin but XCode is not installed (i.e., only the Command
    # Line Tools are available), then Bazel will make ar_executable point to
    # "/usr/bin/libtool". Since we call ar directly, override it.
    # TODO: remove this if Bazel fixes its behavior.
    # Upstream ticket: https://github.com/bazelbuild/bazel/issues/5127.
    if tools["ar"].find("libtool") >= 0:
        tools["ar"] = "/usr/bin/ar"

    return CcInteropInfo(
        tools = struct(**tools),
        files = ctx.files._cc_toolchain,
        hdrs = hdrs.to_list(),
        cpp_flags = cpp_flags,
        include_args = include_args,
        compiler_flags = compiler_flags,
        # XXX this might not be the right set of flags for all situations,
        # but this will anyways all be replaced (once implemented) by
        # https://github.com/bazelbuild/bazel/issues/4571.
        linker_flags = linker_flags,
    )

def _cc_import_impl(ctx):
    strip_prefix = ctx.attr.strip_include_prefix

    # cc_library's strip_include_prefix attribute accepts both absolute and
    # relative paths.  For simplicity we currently only implement absolute
    # paths.
    if strip_prefix.startswith("/"):
        prefix = strip_prefix[1:]
    else:
        prefix = paths.join(ctx.label.workspace_root, ctx.label.package, strip_prefix)

    roots = set.empty()
    for f in ctx.files.hdrs:
        # If it's a generated file, strip off the bin or genfiles prefix.
        path = f.path
        if path.startswith(ctx.bin_dir.path):
            path = paths.relativize(path, ctx.bin_dir.path)
        elif path.startswith(ctx.genfiles_dir.path):
            path = paths.relativize(path, ctx.genfiles_dir.path)

        if not path.startswith(prefix):
            fail("Header {} does not have expected prefix {}".format(
                path,
                prefix,
            ))
        roots = set.insert(roots, f.root.path if f.root.path else ".")

    include_directories = [paths.join(root, prefix) for root in set.to_list(roots)]
    return [
        DefaultInfo(files = depset(ctx.attr.shared_library.files)),
        CcSkylarkApiProviderHacked(
            transitive_headers =
                depset(transitive = [l.files for l in ctx.attr.hdrs]),
            include_directories = include_directories,
        ),
    ]

# XXX This is meant as a drop-in replacement for the native cc_import,
# but it's a temporary hack. It's only necessary because the native
# cc_import does not provide CcSkylarkApiProvider. So we write our own
# rule that does just that. See
# https://github.com/bazelbuild/bazel/issues/4369.
haskell_cc_import = rule(
    _cc_import_impl,
    attrs = {
        "shared_library": attr.label(
            # NOTE We do not list all extensions here because .so libraries may
            # have numeric suffixes like foo.so.1.2.3, and if they also have
            # SONAME with numeric suffix, matching file must be provided, so this
            # attributes must accept libraries with almost arbitrary extensions.
            # It would be easier if Skylark supported regexps.
            allow_files = True,
            doc = """A single precompiled shared library.

Bazel ensures it is available to the binary that depends on it
during runtime.
""",
        ),
        "hdrs": attr.label_list(
            allow_files = [".h"],
            doc = """

The list of header files published by this precompiled library to be
directly included by sources in dependent rules.
""",
        ),
        "strip_include_prefix": attr.string(
            doc = """
The prefix to strip from the paths of the headers of this rule.
When set, the headers in the `hdrs` attribute of this rule are
accessible at their path (relative to the repository) with this
prefix cut off.

If it's a relative path, it's taken as a package-relative one. If it's an
absolute one, it's understood as a repository-relative path.
""",
        ),
    },
)
"""Imports a prebuilt shared library.

Use this to make `.so`, `.dll`, `.dylib` files residing in external
[external repositories][bazel-ext-repos] available to Haskell rules.

*This rule is temporary replacement for [cc_import][cc_import] and
will be deprecated in the future.*

Example:
  ```bzl
  haskell_cc_import(name = "zlib", shared_library = "@zlib//:lib")

  haskell_import(
    name = "base_pkg",
    package = "base",
  )

  haskell_binary(
    name = "crc32sum",
    srcs = ["Main.hs"],
    deps = [
      "bazel_pkg",
      ":zlib",
    ],
  )
  ```

[bazel-ext-repos]: https://docs.bazel.build/versions/master/external.html
[cc_import]: https://docs.bazel.build/versions/master/be/c-cpp.html#cc_import
"""

def _cc_haskell_import(ctx):
    dyn_libs = set.empty()

    if HaskellBuildInfo in ctx.attr.dep:
        set.mutable_union(dyn_libs, ctx.attr.dep[HaskellBuildInfo].dynamic_libraries)
    else:
        fail("{0} has to provide `HaskellBuildInfo`".format(ctx.attr.dep.label.name))

    if HaskellBinaryInfo in ctx.attr.dep:
        bin = ctx.attr.dep[HaskellBinaryInfo].binary
        dyn_lib = ctx.actions.declare_file("lib{0}.so".format(bin.basename))
        ln(ctx, bin, dyn_lib)
        set.mutable_insert(dyn_libs, dyn_lib)

    return [
        DefaultInfo(
            files = set.to_depset(dyn_libs),
            default_runfiles = ctx.runfiles(
                files = ctx.attr.dep.default_runfiles.files.to_list(),
                collect_default = True,
            ),
            data_runfiles = ctx.runfiles(
                files = ctx.attr.dep.data_runfiles.files.to_list(),
                collect_data = True,
            ),
        ),
    ]

cc_haskell_import = rule(
    _cc_haskell_import,
    attrs = {
        "dep": attr.label(
            doc = """
Target providing a `HaskellLibraryInfo` or `HaskellBinaryInfo`, such as
`haskell_library` or `haskell_binary`.
""",
        ),
    },
    toolchains = ["@io_tweag_rules_haskell//haskell:toolchain"],
)
"""Exports a Haskell library as a CC library.

Given a [haskell_library](#haskell_library) or
[haskell_binary](#haskell_binary) input, outputs the shared object files
produced as well as the object files it depends on directly and
transitively. This is very useful if you want to link in a Haskell shared
library from `cc_library`.

There is a caveat: this will not provide any shared libraries that
aren't explicitly given to it. This means that if you're using
`prebuilt_dependencies` and relying on GHC to provide those objects,
they will not be present here. You will have to provide those
separately to your `cc_library`. If you're getting
`prebuilt_dependencies` from your toolchain, you will likely want to
extract those and pass them in as well.

*This rule is temporary and only needed until the Bazel C/C++
"sandwich" (see [bazelbuild/bazel#2163][bazel-cpp-sandwich]) is
implemented. This rule will be deprecated in the future.*

Example:
  ```bzl
  haskell_library(
    name = "my-lib",
    ...
  )

  cc_haskell_import(
    name = "my-lib-objects",
    dep = ":my-lib",
  )

  cc_library(
    name = "my-cc",
    srcs = ["main.c", ":my-lib-objects"],
  )
  ```

[bazel-cpp-sandwich]: https://github.com/bazelbuild/bazel/issues/2163
"""
