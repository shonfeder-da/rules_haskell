load(
    "@bazel_skylib//lib:unittest.bzl",
    "asserts",
    unit = "unittest",
)
load("//haskell:private/actions/link.bzl", "create_rpath_entry", "parent_dir_path")
load("//haskell:private/list.bzl", "list")

def parent_dir_path_test_impl(ctx):
    env = unit.begin(ctx)
    asserts.equals(
        env,
        expected = ctx.attr.output,
        actual = parent_dir_path(ctx.attr.filename),
    )
    unit.end(env)

parent_dir_path_test = unit.make(
    parent_dir_path_test_impl,
    attrs = {
        "filename": attr.string(),
        "output": attr.string_list(),
    },
)

def create_rpath_entry_test_impl(ctx):
    env = unit.begin(ctx)
    asserts.equals(
        env,
        expected = ctx.attr.output,
        actual = create_rpath_entry(
            struct(short_path = ctx.attr.binary_short_path),
            struct(short_path = ctx.attr.dependency_short_path),
            keep_filename = ctx.attr.keep_filename,
            prefix = ctx.attr.prefix,
        ),
    )
    unit.end(env)

create_rpath_entry_test = unit.make(
    create_rpath_entry_test_impl,
    attrs = {
        "binary_short_path": attr.string(),
        "dependency_short_path": attr.string(),
        "keep_filename": attr.bool(),
        "prefix": attr.string(),
        "output": attr.string(),
    },
)

def compare_x(el):
    return el.x

def dedup_on_test_impl(ctx):
    env = unit.begin(ctx)
    asserts.equals(
        env,
        expected = [],
        actual = list.dedup_on([], compare_x),
    )
    asserts.equals(
        env,
        expected = [struct(x = 3)],
        actual = list.dedup_on(
            [struct(x = 3), struct(x = 3), struct(x = 3)],
            compare_x,
        ),
    )
    asserts.equals(
        env,
        expected = [struct(x = 3), struct(x = 4), struct(x = 5)],
        actual = list.dedup_on(
            [struct(x = 3), struct(x = 4), struct(x = 3), struct(x = 5), struct(x = 3)],
            compare_x,
        ),
    )
    unit.end(env)

dedup_on_test = unit.make(dedup_on_test_impl)
