platform ""
    requires {} {
        view : U64 -> Tree,
    }
    exposes []
    packages { roc: "nightly-2026-10-11-7d256b9" }
    provides {
        "roc_view": view_for_host,
    }

# The compiler boxes each Fork payload. The glue refuses this union, because
# the host cannot free a Box.
Tree := [Leaf(U64), Fork(Tree, Tree)]

view_for_host : U64 -> Tree
view_for_host = |n| view(n)
