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
    # GHC does not support -dynamic-too on Windows.
    linkstatic = select({
        "@bazel_tools//src/conditions:windows": True,
        "//conditions:default": False,
    }),
    src_strip_prefix = "src",
)

haskell_test(
    name = "binary-with-lib",
    srcs = ["Main.hs"],
    visibility = ["//visibility:public"],
    deps = [
        ":base_pkg",
        ":lib",
    ],
)
