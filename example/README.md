# Examples

Four platforms with no host and no build target, so `roc glue` runs against
them directly:

| Directory | Shows |
|---|---|
| `platform/` | Records, a list and scalars passed by value. |
| `boxed/platform/` | A `Box` model, a `Str` inside a list of records, and lists of `U16`. It is the rocco engine's platform header. |
| `unions/platform/` | One tag union per case: no payloads, one payload per tag, a multi-field payload, a union in a payload, a union in a record and a union in a list. |
| `tree/platform/` | A nominal union that refers to itself through a `List`: a UI tree of `Box` and `Text`. |

Each has a committed output in `expected/`. `check.sh` regenerates them,
compares them, compiles them with `-vet -strict-style`, runs the helper tests
in `test/` against the boxed output, and runs the layout tests in
`unions/test/` and `tree/test/` against the unions and tree outputs. It then
checks that the glue refuses `refused/platform/`, whose union refers to itself
through a Box, and that the error names the type:

    ./example/check.sh

`test/host_stub.odin` stands in for the host's `roc_alloc` and `roc_dealloc`.
