platform ""
    requires {} {
        init: U64 -> { count : U64, points : List({ x : F32, y : F32 }) },
        step: { count : U64, points : List({ x : F32, y : F32 }) }, F32 -> { count : U64, points : List({ x : F32, y : F32 }) },
    }
    exposes []
    packages { roc: "nightly-2026-09-12-220fd47" }
    provides {
        "roc_init": init_for_host,
        "roc_step": step_for_host,
    }
    targets: {
        inputs_dir: "targets/",
        arm64mac: { inputs: [ "libhost.a", app ] },
    }

Point : { x : F32, y : F32 }
State : { count : U64, points : List(Point) }

init_for_host : U64 -> State
init_for_host = |n| init(n)

step_for_host : State, F32 -> State
step_for_host = |state, dt| step(state, dt)
