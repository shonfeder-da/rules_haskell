load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_import",
    "haskell_library",
    "haskell_test",
)

package(default_testonly = 1)

haskell_import(
    name = "base_pkg",
    package = "base",
)

haskell_library(
    name = "lib",
    srcs = glob(["src/*.hs"]),
    src_strip_prefix = "src",
    # GHC does not support -dynamic-too on Windows.
    linkstatic = select({
        "@bazel_tools//src/conditions:windows": True,
        "//conditions:default": False,
    }),
)

haskell_test(
    name = "binary-with-lib",
    srcs = ["Main.hs"],
    visibility = ["//visibility:public"],
    deps = [
        ":lib",
        ":base_pkg",
    ],
)
