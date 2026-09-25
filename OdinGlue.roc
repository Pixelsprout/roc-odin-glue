## OdinGlue.roc — generate Odin bindings for a Roc platform's ABI.
##
## Usage:
##   roc glue ./OdinGlue.roc <out-dir> <platform>/main.roc
##
## Emits one Odin file declaring the platform's records, the RocList header,
## and the extern signatures the host links against, with compile-time
## assertions pinning every committed offset, size and alignment.
##
## Set `odin_package` below before first use.
##
## Supports: records, lists, and the scalar builtins. Anything else crashes
## naming the type, by design — see README.
##
app [make_glue] { pf: platform glue }

import pf.Types exposing [Types]
import pf.File exposing [File]
import pf.GlueInput exposing [GlueInput]
import pf.TypeTable exposing [TypeTable]
import pf.RocName exposing [RocName]
import pf.AbiLayout exposing [AbiLayout]
import pf.ProvidesEntry exposing [ProvidesEntry]

## One name the host will use, the structural key it stands for, and the type
## id that carries its layout.
##
## `key` is the compiler's own name for the record's shape, so two paths that
## reach the same record share a key and the second becomes an alias.
Named : { key : Str, name : Str, type_id : U64 }

make_glue : List(Types) -> Try(List(File), Str)
make_glue = |types_list| {
    input = GlueInput.from_types(types_list)
    table = TypeTable.from_list(input.types)
    plan = name_plan(table, input.provides_entries)

    dbg plan

    content = file_header
        .concat(str_struct)
        .concat(list_struct(table))
        .concat(structs(table, plan))
        .concat(foreign_block(table, plan, input.provides_entries))

    Ok([{ name: "roc_platform_abi.odin", content }])
}

# ------------------------------------------------------------------- naming

# Builds a name plan from the type table and provides entries.
name_plan : TypeTable, List(ProvidesEntry) -> List(Named)
name_plan = |table, provides_entries| {
    provides_entries.fold(
        [],
        |acc, entry| {
            bare = Str.drop_prefix(entry.ffi_symbol, "roc_")
            base = "Roc_${RocName.from_str(bare).to_pascal_clean()}"
            match table.get(entry.type_id) {
                RocFunction(func) => {
                    var $plan = acc
                    var $arg_index = 0

                    for arg_type_id in func.args {
                        $plan = walk(
                            table,
                            $plan,
                            arg_type_id,
                            "${base}_Arg${U64.to_str($arg_index)}",
                        )
                        $arg_index = $arg_index + 1
                    }

                    walk(table, $plan, func.ret, base)
                }
                _ => acc,
            }
        }
    )
}

# walks the type table, naming each record/function based on its path
walk : TypeTable, List(Named), U64, Str -> List(Named)
walk = |table, plan, type_id, name| {
    match table.get(type_id) {
        RocList(elem_id) => {
            # Passes same name to its element type
            walk(table, plan, elem_id, name)
        }
        RocRecord(rec) => {
            if has_name(plan, name) {
                return plan
            }

            var $plan = plan.append({
                key: rec.name,
                name,
                type_id,
            })
            # Passes same name to each field
            for field in rec.fields {
                if !field.is_padding {
                    $plan = walk(
                        table,
                        $plan,
                        field.type_id,
                       "${name}_${RocName.from_str(field.name).to_pascal_clean()}" ,
                    )
                }
            }
            $plan
        }
        _ => plan
    }
}

# Returns whether the plan has a named entry for the given key.
has_name : List(Named), Str -> Bool
has_name = |plan, name| {
    var $found = Bool.False
    for entry in plan {
        if entry.name == name {
            $found = Bool.True
        }
    }
    $found
}

# The name the struct is defined under: the first path that reached this shape.
canonical : List(Named), Str -> Str
canonical = |plan, key| {
    var $name = ""
    for entry in plan {
        if entry.key == key and $name == "" {
            $name = entry.name
        }
    }

    if $name == "" {
        crash "OdinGlue: no name was planned for record ${key}"
    }

    $name
}

# ---------------------------------------------------------------- type names

# Maps a type id to its Odin spelling.
# TODO: handle other types such as Tagged Unions
odin_type : TypeTable, List(Named), U64 -> Str
odin_type = |table, plan, type_id| {
    match table.get(type_id) {
        RocU8 => "u8"
        RocU16 => "u16"
        RocU32 => "u32"
        RocU64 => "u64"
        RocU128 => "u128"
        RocI8 => "i8"
        RocI16 => "i16"
        RocI32 => "i32"
        RocI64 => "i64"
        RocI128 => "i128"
        RocF32 => "f32"
        RocF64 => "f64"
        RocBool => "bool"
        RocStr => "Roc_Str"
        RocDec => "i128"
        RocBox(_elem_id) => "rawptr"
        RocList(elem_id) => "Roc_List(${odin_type(table, plan, elem_id)})"
        RocRecord(rec) => canonical(plan, rec.name)
        RocUnit => "struct{}"
        RocUnknown(_) => "rawptr"
        _other => crash "OdinGlue: no Odin spelling for ${table.structural_token(type_id)} (type id ${U64.to_str(type_id)})"
    }
}

# ------------------------------------------------------------------ preamble

## The Odin package name written at the top of the generated file.
## Change this to the package your host lives in.
odin_package : Str
odin_package = "engine"

file_header : Str
file_header =
    "package ${odin_package}\n\n"
        .concat(
            \\// Generated by OdinGlue.roc from the platform's `requires` block.
            \\// Do not edit by hand; regenerate instead:
            \\//   roc glue ./OdinGlue.roc <out-dir> <platform>/main.roc
            \\
            \\// Every offset below is the 64-bit layout. This spec emits one pointer
            \\// width, so the host must be a 64-bit target.
            \\#assert(size_of(uintptr) == 8)
            \\
            \\
        )

## Roc's string representation: pointer + length + capacity, all 8 bytes on 64-bit.
## Always emitted; Roc_Str is used whenever a RocStr field appears.
str_struct : Str
str_struct =
    \\Roc_Str :: struct {
    \\\tbytes:                [^]u8,
    \\\tcapacity_or_alloc_ptr: uint,
    \\\tlength:               uint,
    \\}
    \\#assert(size_of(Roc_Str) == 24)
    \\#assert(align_of(Roc_Str) == 8)
    \\
    \\

## The list header, with its size and alignment read off the type table rather
## than assumed.
list_struct : TypeTable -> Str
list_struct = |table| {
    var $size = 0
    var $align = 0

    for entry in table.entries() {
        match entry.repr {
            RocList(_) => {
                $size = entry.layout.size64
                $align = entry.layout.alignment64
            }
            _ => {}
        }
    }

    if $size == 0 {
        return ""
    }

    \\Roc_List :: struct($T: typeid) {
    \\	elements:              [^]T,
    \\	length:                uint,
    \\	capacity_or_alloc_ptr: uint,
    \\}
    \\
    \\
        .concat("#assert(size_of(Roc_List(u8)) == ${U64.to_str($size)})\n")
        .concat("#assert(align_of(Roc_List(u8)) == ${U64.to_str($align)})\n\n")
}

# ------------------------------------------------------------------- structs

## TODO 4. Walk the plan in order. The first name for a shape gets the struct
## definition; every later name for the same shape gets an Odin alias.
structs : TypeTable, List(Named) -> Str
structs = |table, plan| {
    var $out = ""
    var $defined = []
    for entry in plan {
        if $defined.contains(entry.key) {
            $out = $out.concat("${entry.name} :: ${canonical(plan, entry.key)}\n")
        } else {
            $defined = $defined.append(entry.key)
            $out = $out.concat(one_struct(table, plan, entry.name, TypeTable.layout(table, entry.type_id)))
        }
    }
    $out.concat("\n")
}

## TODO 5. One struct, its fields in the order the layout gives them, followed
## by the assertions that pin it. Emit a padding field as a byte array and do
## not assert an offset for it. For every real field assert both its offset and
## its own size — an offset alone will not catch a field narrowed into slack.
one_struct : TypeTable, List(Named), Str, AbiLayout -> Str
one_struct = |table, plan, name, layout| {
    var $out = "${name} :: struct {\n"
    var $pad = 0
    for field in layout.record_fields() {
        if field.is_padding {
            $out = $out.concat("\t_pad${U64.to_str($pad)}: [${U64.to_str(field.size64)}]u8,\n")
            $pad = $pad + 1
        } else {
            $out = $out.concat("\t${field.name}: ${odin_type(table, plan, field.type_id)},\n")
        }
    }
    $out = $out.concat("}\n\n")

    # Odin assertions
    $out = $out.concat("#assert(size_of(${name}) == ${U64.to_str(layout.size64)})\n")
    $out = $out.concat("#assert(align_of(${name}) == ${U64.to_str(layout.alignment64)})\n")
    for field in layout.record_fields() {
        if !field.is_padding {
            $out = $out.concat("#assert(offset_of(${name}, ${field.name}) == ${U64.to_str(field.offset64)})\n")
            $out = $out.concat("#assert(size_of(type_of(${name}{}.${field.name})) == ${U64.to_str(field.size64)})\n")
        }
    }

    $out.concat("\n")
}

# ------------------------------------------------------------- foreign block

## The extern declarations the host links against. The block names no library:
## "system:c" becomes an input file named c for lib.exe on Windows.
foreign_block : TypeTable, List(Named), List(ProvidesEntry) -> Str
foreign_block = |table, plan, provides_entries| {
    var $out =
        \\// The Roc app defines these symbols at the final link.
        \\@(default_calling_convention = "c")
        \\foreign {
        \\

    for entry in provides_entries {
        match table.get(entry.type_id) {
            RocFunction(func) => {
                var $args = ""
                var $i = 0
                for arg_id in func.args {
                    sep = if $i == 0 { "" } else { ", " }
                    $args = $args.concat("${sep}arg${U64.to_str($i)}: ${odin_type(table, plan, arg_id)}")
                    $i = $i + 1
                }
                $out = $out.concat(
                    "	${entry.ffi_symbol} :: proc(${$args}) -> ${odin_type(table, plan, func.ret)} ---\n",
                )
            }
            _ => {}
        }
    }

    $out.concat("}\n")
}
