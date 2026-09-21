# OdinGlue

A [Roc](https://github.com/roc-lang/roc) glue spec that generates **Odin**
bindings for a platform's ABI.

Roc ships glue specs for C, Rust and Zig. This is a fourth, for
[Odin](https://odin-lang.org). Point it at your platform's `main.roc` and it
emits one Odin file containing the records your platform exchanges with the
host, the `RocList` header, the extern signatures to link against, and
compile-time assertions pinning every committed offset, size and alignment.

> **Status: works, and narrow.** Verified against
> `nightly-2026-09-12-220fd47` on `arm64mac`. Roc is pre-alpha and the glue
> platform API moves; treat everything here as a snapshot. It handles the types
> a small platform needs and crashes loudly on the rest — see
> [Supported types](#supported-types).

## Quick start

```sh
# 1. set your Odin package name
$EDITOR OdinGlue.roc          # odin_package = "engine"

# 2. generate, straight into your Odin package directory
roc glue ./OdinGlue.roc ./src path/to/platform/main.roc
```

Try it against the bundled example, which needs no host and no build target:

```sh
roc glue ./OdinGlue.roc /tmp/out ./example/platform/main.roc
diff /tmp/out/roc_platform_abi.odin example/expected/roc_platform_abi.odin
```

## What it generates

For a platform requiring
`{ count : U64, points : List({ x : F32, y : F32 }) }`:

```odin
package engine

#assert(size_of(uintptr) == 8)

Roc_List :: struct($T: typeid) {
	elements:              [^]T,
	length:                uint,
	capacity_or_alloc_ptr: uint,
}

#assert(size_of(Roc_List(u8)) == 24)
#assert(align_of(Roc_List(u8)) == 8)

Roc_Init :: struct {
	count: u64,
	points: Roc_List(Roc_Init_Points),
}

#assert(size_of(Roc_Init) == 32)
#assert(align_of(Roc_Init) == 8)
#assert(offset_of(Roc_Init, count) == 0)
#assert(size_of(type_of(Roc_Init{}.count)) == 8)
#assert(offset_of(Roc_Init, points) == 8)
#assert(size_of(type_of(Roc_Init{}.points)) == 24)

/* … Roc_Init_Points, then: */

Roc_Step_Arg0 :: Roc_Init
Roc_Step :: Roc_Init

foreign import roc_app "system:c"

@(default_calling_convention = "c")
foreign roc_app {
	roc_init :: proc(arg0: u64) -> Roc_Init ---
	roc_step :: proc(arg0: Roc_Init, arg1: f32) -> Roc_Init ---
}
```

The full file is in [`example/expected/`](example/expected/).

### Naming

Roc records are structural: the compiler identifies a record by a hash of its
shape (`__AnonStruct_6a24706498ee69c4`) and the alias you wrote in the platform
header is not part of its identity. A glue spec therefore has to invent names.

Zig's spec emits the hash and adds readable aliases beside it. **OdinGlue names
each record by the path that reaches it from a `provides` entry**, so no hash
appears in the output: the return type of `roc_init` is `Roc_Init`, its
`points` field's element type is `Roc_Init_Points`, and a shape reached by a
second path becomes an alias (`Roc_Step_Arg0 :: Roc_Init`).

That matters when a record changes. A hash is a function of the *shape*, so it
moves whenever a field does, and every host mentioning it must be edited. A
path name is a function of the platform's *interface*, which changes far less
often — so a host line like

```odin
My_State :: Roc_Init
```

survives adding a field to the record. Regenerate and rebuild; change nothing.

## Supported types

| Roc | Odin |
|---|---|
| `U8`–`U128`, `I8`–`I128` | `u8`…`u128`, `i8`…`i128` |
| `F32`, `F64` | `f32`, `f64` |
| `Bool` | `bool` |
| `List(T)` | `Roc_List(T)` |
| records | a generated `struct`, in committed field order |

**Everything else crashes**, naming the type and its id:

```
crashed with message: OdinGlue: no Odin spelling for tu:Result (type id 7)
```

That is deliberate. A generator that guesses produces a file which compiles,
asserts cleanly, and reads garbage at runtime. Unimplemented, and each is real
work rather than a missing match arm:

- **`Str`** — 24 bytes with a small-string optimisation, not Odin's `string`.
- **`Dec`** — `i128` scaled by 10<sup>18</sup>, size 16, **align 16**. Needs a
  wrapper struct so it is not mistaken for an integer.
- **Tag unions** — need a `struct #raw_union` payload plus an explicit
  discriminant at `discriminant_offset`. Do *not* map them to Odin's `union`,
  which owns its own tag placement and values. Discriminants are assigned
  alphabetically, and multi-argument payloads are reordered by alignment.
- **`Box`**, SIMD vectors, recursive types.

## Three things to know

### The generated package name is a constant

`odin_package` at the top of `OdinGlue.roc`. `roc glue` passes no arguments to
a spec, so this is an edit rather than a flag.

### Regenerate *before* you build, in one chain

Nothing compares the generated file against the Roc it came from. Change a
record without regenerating and **both compilers report success** while the
host reads garbage. Worse, each tool in the chain silently consumes the
previous one's stale output on failure: a crashing glue spec leaves the old
`.odin` in place, and a failed Odin build leaves the old archive for `roc
build` to link.

```sh
roc glue ./OdinGlue.roc ./src platform/main.roc \
  && odin build src -build-mode:static -out:platform/targets/arm64mac/libhost.a \
  && roc build --output=./app.bin main.roc
```

### The assertions are narrower than they look

They compare Odin against Odin. They catch a field emitted in the wrong order,
and — because each field's own size is asserted, not just its offset — a field
narrowed into a neighbour's alignment slack. They **cannot** catch a stale
file, and they cannot catch a type of the right width but the wrong meaning
(`u32` where Roc has an `f32` passes every one of them). Use the chain above.

## Limitations

- **64-bit only.** The spec emits the 64-bit layout and asserts
  `size_of(uintptr) == 8`. The type table carries both widths
  (`offset32`/`offset64`), so 32-bit support is additive work, not a redesign.
- Verified on `arm64mac`. Nothing else has been tried.
- No deallocation or refcount helpers are generated. The host implements
  `roc_alloc`, `roc_dealloc` and `roc_realloc` itself.

## How it works

A glue spec is an ordinary Roc app — `app [make_glue] { pf: platform glue }` —
that receives the compiler's reflected type table and returns files. Every ABI
fact comes from that table; nothing is inferred.

The smallest possible spec is twelve lines and prints the whole table, which is
the fastest way to see what you are working with:

```roc
app [make_glue] { pf: platform glue }

import pf.Types exposing [Types]
import pf.File exposing [File]

make_glue : List(Types) -> Try(List(File), Str)
make_glue = |types_list| {
    dbg types_list

    Ok([])
}
```

**A `crash` anywhere discards buffered `dbg` output**, so instrument a spec
that completes, not one that aborts.

Fields arrive in committed layout order and
[`AbiFieldLayout`](https://github.com/roc-lang/roc/blob/main/src/glue/platform/AbiFieldLayout.roc)'s
doc comment instructs emitters not to re-sort them — so a spec never
reimplements Roc's field-order rule. Only a hand-transcriber needs to know it.

## References

- [`src/glue/platform`](https://github.com/roc-lang/roc/tree/main/src/glue/platform)
  — the typed API a spec consumes. 18 files, ~660 lines; read it before
  guessing.
- [`src/glue/README.md`](https://github.com/roc-lang/roc/blob/main/src/glue/README.md)
  — why bindings are generated rather than hand-written.
- [Roc platforms reference](https://github.com/roc-lang/roc/blob/main/docs/langref/platforms.md)
- [Roc Zulip](https://roc.zulipchat.com/) — where Roc development happens.

## Licence

Not yet chosen. Roc itself is UPL-1.0; matching it is the obvious choice if
this is ever offered upstream.
