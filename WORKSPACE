workspace(name = "io_tweag_rules_haskell")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@io_tweag_rules_haskell//haskell:repositories.bzl", "haskell_repositories")

haskell_repositories()

rules_nixpkgs_version = "c232b296e795ad688854ff3d3d2de6e7ad45f0b4"

rules_nixpkgs_sha256 = "5883ea01f3075354ab622cfe82542da01fe2b57a48f4c3f7610b4d14a3fced11"

http_archive(
    name = "io_tweag_rules_nixpkgs",
    sha256 = rules_nixpkgs_sha256,
    strip_prefix = "rules_nixpkgs-%s" % rules_nixpkgs_version,
    urls = ["https://github.com/tweag/rules_nixpkgs/archive/%s.tar.gz" % rules_nixpkgs_version],
)

load(
    "@io_tweag_rules_nixpkgs//nixpkgs:nixpkgs.bzl",
    "nixpkgs_cc_configure",
    "nixpkgs_local_repository",
    "nixpkgs_package",
)
load(
    "@io_tweag_rules_haskell//haskell:nixpkgs.bzl",
    "haskell_nixpkgs_package",
    "haskell_nixpkgs_packageset",
)

haskell_nixpkgs_package(
    name = "ghc",
    attribute_path = "haskellPackages.ghc",
    build_file = "//haskell:ghc.BUILD",
    nix_file = "//tests:ghc.nix",
    # rules_nixpkgs assumes we want to read from `<nixpkgs>` implicitly
    # if `repository` is not set, but our nix_file uses `./nixpkgs/`.
    # TODO(Profpatsch)
    repositories = {"nixpkgs": "//nixpkgs:NOTUSED"},
)

http_archive(
    name = "com_google_protobuf",
    sha256 = "73fdad358857e120fd0fa19e071a96e15c0f23bb25f85d3f7009abfd4f264a2a",
    strip_prefix = "protobuf-3.6.1.3",
    urls = ["https://github.com/google/protobuf/archive/v3.6.1.3.tar.gz"],
)

nixpkgs_local_repository(
    name = "nixpkgs",
    nix_file = "//nixpkgs:default.nix",
)

test_ghc_version = "8.6.3"

test_compiler_flags = [
    "-XStandaloneDeriving",  # Flag used at compile time
    "-threaded",  # Flag used at link time

    # Used by `tests/repl-flags`
    "-DTESTS_TOOLCHAIN_COMPILER_FLAGS",
    # this is the default, so it does not harm other tests
    "-XNoOverloadedStrings",
]

test_haddock_flags = ["-U"]

test_repl_ghci_args = [
    # The repl test will need this flag, but set by the local
    # `repl_ghci_args`.
    "-UTESTS_TOOLCHAIN_REPL_FLAGS",
    # The repl test will need OverloadedString
    "-XOverloadedStrings",
]

load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_register_ghc_bindists",
    "haskell_register_ghc_nixpkgs",
)

haskell_register_ghc_nixpkgs(
    compiler_flags = test_compiler_flags,
    haddock_flags = test_haddock_flags,
    locale_archive = "@glibc_locales//:locale-archive",
    nix_file = "//tests:ghc.nix",
    repl_ghci_args = test_repl_ghci_args,
    version = test_ghc_version,
)

haskell_register_ghc_bindists(version = test_ghc_version)

register_toolchains(
    "//tests:c2hs-toolchain",
    "//tests:doctest-toolchain",
    "//tests:protobuf-toolchain",
)

nixpkgs_cc_configure(
    nix_file = "//nixpkgs:cc-toolchain.nix",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "zlib",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "sphinx",
    attribute_path = "python36Packages.sphinx",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "graphviz",
    attribute_path = "graphviz",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "zip",
    attribute_path = "zip",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "zlib.dev",
    build_file_content = """
load("@io_tweag_rules_haskell//haskell:haskell.bzl", "haskell_cc_import")
package(default_visibility = ["//visibility:public"])

filegroup (
    name = "include",
    srcs = glob(["include/*.h"]),
    testonly = 1,
)

haskell_cc_import(
    name = "zlib",
    shared_library = "@zlib//:lib",
    hdrs = [":include"],
    testonly = 1,
    strip_include_prefix = "include",
)
""",
    repository = "@nixpkgs",
)

nixpkgs_package(
    name = "glibc_locales",
    attribute_path = "glibcLocales",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "locale-archive",
    srcs = ["lib/locale/locale-archive"],
)
""",
    repository = "@nixpkgs",
)

haskell_nixpkgs_packageset(
    name = "hackage-packages",
    base_attribute_path = "haskellPackages",
    nix_file = "//tests:ghc.nix",
    nixopts = [
        "-j",
        "1",
    ],
    repositories = {"nixpkgs": "@nixpkgs"},
)

load("@hackage-packages//:packages.bzl", "import_packages")

import_packages(name = "hackage")

# zlib as a Haskell library

http_archive(
    name = "haskell_zlib",
    build_file = "//tests:BUILD.zlib",
    strip_prefix = "zlib-0.6.2",
    urls = ["https://hackage.haskell.org/package/zlib-0.6.2/zlib-0.6.2.tar.gz"],
)

load("@bazel_tools//tools/build_defs/repo:jvm.bzl", "jvm_maven_import_external")

jvm_maven_import_external(
    name = "org_apache_spark_spark_core_2_10",
    artifact = "org.apache.spark:spark-core_2.10:1.6.0",
    artifact_sha256 = "28aad0602a5eea97e9cfed3a7c5f2934cd5afefdb7f7c1d871bb07985453ea6e",
    licenses = ["notice"],
    server_urls = ["http://central.maven.org/maven2"],
)

# c2hs rule in its own repository
local_repository(
    name = "c2hs_repo",
    path = "tests/c2hs/repo",
)

# For Skydoc

nixpkgs_package(
    name = "nixpkgs_nodejs",
    # XXX Indirection derivation to make all of NodeJS rooted in
    # a single directory. We shouldn't need this, but it's
    # a workaround for
    # https://github.com/bazelbuild/bazel/issues/2927.
    nix_file_content = """
    with import <nixpkgs> {};
    runCommand "nodejs-rules_haskell" { buildInputs = [ nodejs ]; } ''
      mkdir -p $out/nixpkgs_nodejs
      cd $out/nixpkgs_nodejs
      for i in ${nodejs}/*; do ln -s $i; done
      ''
    """,
    nixopts = [
        "--option",
        "sandbox",
        "false",
    ],
    repository = "@nixpkgs",
)

http_archive(
    name = "build_bazel_rules_nodejs",
    sha256 = "f79f605a920145216e64991d6eff4e23babc48810a9efd63a31744bb6637b01e",
    strip_prefix = "rules_nodejs-b4dad57d2ecc63d74db1f5523593639a635e447d",
    # Tip of https://github.com/bazelbuild/rules_nodejs/pull/471.
    urls = ["https://github.com/mboes/rules_nodejs/archive/b4dad57d2ecc63d74db1f5523593639a635e447d.tar.gz"],
)

http_archive(
    name = "io_bazel_rules_sass",
    sha256 = "1e135452dc627f52eab39a50f4d5b8d13e8ed66cba2e6da56ac4cbdbd776536c",
    strip_prefix = "rules_sass-1.15.2",
    urls = ["https://github.com/bazelbuild/rules_sass/archive/1.15.2.tar.gz"],
)

load("@io_bazel_rules_sass//:package.bzl", "rules_sass_dependencies")

rules_sass_dependencies()

load("@io_bazel_rules_sass//:defs.bzl", "sass_repositories")

sass_repositories()

load("@build_bazel_rules_nodejs//:defs.bzl", "node_repositories")

node_repositories(
    vendored_node = "@nixpkgs_nodejs",
)

http_archive(
    name = "io_bazel_skydoc",
    sha256 = "19eb6c162075707df5703c274d3348127625873dbfa5ff83b1ef4b8f5dbaa449",
    strip_prefix = "skydoc-0.2.0",
    urls = ["https://github.com/bazelbuild/skydoc/archive/0.2.0.tar.gz"],
)

load("@io_bazel_skydoc//:setup.bzl", "skydoc_repositories")

skydoc_repositories()

# For buildifier

http_archive(
    name = "io_bazel_rules_go",
    sha256 = "8be57ff66da79d9e4bd434c860dce589195b9101b2c187d144014bbca23b5166",
    strip_prefix = "rules_go-0.16.3",
    urls = ["https://github.com/bazelbuild/rules_go/archive/0.16.3.tar.gz"],
)

http_archive(
    name = "com_github_bazelbuild_buildtools",
    sha256 = "c730536b703b10294675743579afa78055d3feda92e8cb03d2fb76ad97396770",
    strip_prefix = "buildtools-0.20.0",
    urls = ["https://github.com/bazelbuild/buildtools/archive/0.20.0.tar.gz"],
)

# A repository that generates the Go SDK imports, see ./tools/go_sdk/README
local_repository(
    name = "go_sdk_repo",
    path = "tools/go_sdk",
)

load("@go_sdk_repo//:sdk.bzl", "gen_imports")

gen_imports(name = "go_sdk_imports")

load("@go_sdk_imports//:imports.bzl", "load_go_sdk")

load_go_sdk()

load("@com_github_bazelbuild_buildtools//buildifier:deps.bzl", "buildifier_dependencies")

buildifier_dependencies()
