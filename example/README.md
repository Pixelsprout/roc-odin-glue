# Examples

Two platforms with no host and no build target, so `roc glue` runs against
them directly:

| Directory | Shows |
|---|---|
| `platform/` | Records, a list and scalars passed by value. |
| `boxed/platform/` | A `Box` model, a `Str` inside a list of records, and lists of `U16`. It is the rocco engine's platform header. |

Each has a committed output in `expected/`. `check.sh` regenerates both and
compares them, compiles both with `-vet -strict-style`, and runs the helper
tests in `test/` against the boxed output:

    ./example/check.sh

`test/host_stub.odin` stands in for the host's `roc_alloc` and `roc_dealloc`.
