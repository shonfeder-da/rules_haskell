load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_import",
    "haskell_library",
)

haskell_library(
    name = "library-with-cbits",
    srcs = ["AddOne.hsc"],
    linkstatic = False,
    visibility = ["//visibility:public"],
    deps = [
        "//tests/data:ourclibrary",
        "@hackage//:base",
    ],
)

haskell_library(
    name = "library-with-cbits-indirect",
    srcs = ["AddOne2.hs"],
    visibility = ["//visibility:public"],
    deps = [
        ":library-with-cbits",
        "@hackage//:base",
    ],
)

haskell_library(
    name = "library-with-cbits-static",
    srcs = ["AddOne.hsc"],
    visibility = ["//visibility:public"],
    deps = [
        "//tests/data:ourclibrary-static",
        "@hackage//:base",
    ],
)
