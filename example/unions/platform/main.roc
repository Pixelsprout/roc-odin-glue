platform ""
    requires {} {
        view : U64 -> { mode : [Idle, Walk, Jump], shape : [Sphere(F32), Cube({ x : F32, y : F32, z : F32 })], ray : [Miss, Hit(U8, F64, U16)], nested : [Quit, Pick([Small(U8), Big(U32)])], body : { mass : F32, kind : [Rigid, Soft(F32)] }, items : List([Coin(U32), Key]), phase : Phase },
    }
    exposes []
    packages { roc: "nightly-2026-09-27-a3ce7f1" }
    provides {
        "roc_view": view_for_host,
    }

# A nominal union keeps its own name in the glue.
Phase := [Day, Night]

View : {
    mode : [Idle, Walk, Jump],
    shape : [Sphere(F32), Cube({ x : F32, y : F32, z : F32 })],
    ray : [Miss, Hit(U8, F64, U16)],
    nested : [Quit, Pick([Small(U8), Big(U32)])],
    body : { mass : F32, kind : [Rigid, Soft(F32)] },
    items : List([Coin(U32), Key]),
    phase : Phase,
}

view_for_host : U64 -> View
view_for_host = |n| view(n)
