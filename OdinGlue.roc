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
## Supports: records, lists, `Str`, `Box` as an opaque pointer, and the scalar
## builtins. Anything else crashes naming the type, by design — see README.
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
    reached = reachable(table, input.provides_entries)

    content = file_header
        .concat(runtime(table, reached))
        .concat(structs(table, plan))
        .concat(refcount_helpers(table, plan, reached))
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
        RocBool => "bool"
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
        RocStr => "Roc_Str"
        RocDec => "i128"
        # The host never reads inside a box, so its payload type is not emitted.
        RocBox(_) => "rawptr"
        RocList(elem_id) => "Roc_List(${odin_type(table, plan, elem_id)})"
        RocRecord(rec) => canonical(plan, rec.name)
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

# ------------------------------------------------------------------ runtime

## Every type id reachable from a `provides` entry. A box is not entered: its
## payload is the game's, and the host never reads it.
reachable : TypeTable, List(ProvidesEntry) -> List(U64)
reachable = |table, provides_entries| {
    var $seen = []
    for entry in provides_entries {
        $seen = reach(table, $seen, entry.type_id)
    }
    $seen
}

reach : TypeTable, List(U64), U64 -> List(U64)
reach = |table, seen, type_id| {
    if seen.contains(type_id) {
        return seen
    }

    var $seen = seen.append(type_id)
    match table.get(type_id) {
        RocFunction(func) => {
            for arg_id in func.args {
                $seen = reach(table, $seen, arg_id)
            }
            reach(table, $seen, func.ret)
        }
        RocList(elem_id) => reach(table, $seen, elem_id)
        RocRecord(rec) => {
            for field in rec.fields {
                if !field.is_padding {
                    $seen = reach(table, $seen, field.type_id)
                }
            }
            $seen
        }
        _ => $seen
    }
}

## What the reached types need at runtime: the refcount core, the list and
## string headers, and the box helper. Sizes come off the type table.
runtime : TypeTable, List(U64) -> Str
runtime = |table, reached| {
    var $list = ""
    var $str = ""
    var $box = ""
    var $core = ""

    for type_id in reached {
        layout = table.layout(type_id)
        match table.get(type_id) {
            RocList(_) => {
                $list = list_runtime(layout.size64, layout.alignment64)
                $core = core_runtime
            }
            RocStr => {
                $str = str_runtime(layout.size64, layout.alignment64)
                $core = core_runtime
            }
            RocBox(_) => {
                $box = box_runtime
                $core = core_runtime
            }
            _ => {}
        }
    }

    $core.concat($list).concat($str).concat($box)
}

core_runtime : Str
core_runtime =
    \\// The helpers below allocate and free through roc_alloc and roc_dealloc.
    \\// The host defines both in this package, because the Roc app calls them.
    \\//
    \\// A refcounted allocation keeps a header in front of its data. The
    \\// refcount is the int just before the data, and 0 marks static data,
    \\// which is never freed. A list whose elements hold refcounted values also
    \\// keeps its element count in the int before the refcount.
    \\
    \\@(private = "file")
    \\roc_refcount :: proc(data: rawptr) -> ^int {
    \\	return (^int)(uintptr(data) - size_of(int))
    \\}
    \\
    \\@(private = "file")
    \\roc_header :: proc(elem_align: uint, elements_refcounted: bool) -> (header, alignment: uint) {
    \\	header = max(2 * size_of(uint) if elements_refcounted else size_of(uint), elem_align)
    \\	alignment = max(size_of(uint), elem_align)
    \\	return
    \\}
    \\
    \\// Returns the data pointer of a new allocation with refcount 1.
    \\@(private = "file")
    \\roc_alloc_refcounted :: proc(data_bytes, elem_align: uint, elements_refcounted: bool, count: uint) -> rawptr {
    \\	header, alignment := roc_header(elem_align, elements_refcounted)
    \\	base := roc_alloc(header + data_bytes, alignment)
    \\	if base == nil {
    \\		panic("roc_alloc returned nil")
    \\	}
    \\	data := rawptr(uintptr(base) + uintptr(header))
    \\	roc_refcount(data)^ = 1
    \\	if elements_refcounted {
    \\		(^uint)(uintptr(data) - 2 * size_of(uint))^ = count
    \\	}
    \\	return data
    \\}
    \\
    \\// Returns true when this call dropped the last reference.
    \\@(private = "file")
    \\roc_release :: proc(data: rawptr) -> bool {
    \\	if data == nil {
    \\		return false
    \\	}
    \\	rc := roc_refcount(data)
    \\	if rc^ == 0 {
    \\		return false
    \\	}
    \\	rc^ -= 1
    \\	return rc^ == 0
    \\}
    \\
    \\@(private = "file")
    \\roc_free :: proc(data: rawptr, elem_align: uint, elements_refcounted: bool) {
    \\	header, alignment := roc_header(elem_align, elements_refcounted)
    \\	roc_dealloc(rawptr(uintptr(data) - uintptr(header)), alignment)
    \\}
    \\
    \\

## The list header, with its size and alignment read off the type table rather
## than assumed, and the generic list helpers the per-type ones call.
list_runtime : U64, U64 -> Str
list_runtime = |size, align|
    \\Roc_List :: struct($T: typeid) {
    \\	elements:              [^]T,
    \\	length:                uint,
    \\	capacity_or_alloc_ptr: uint,
    \\}
    \\
    \\
        .concat("#assert(size_of(Roc_List(u8)) == ${U64.to_str(size)})\n")
        .concat("#assert(align_of(Roc_List(u8)) == ${U64.to_str(align)})\n\n")
        .concat(
            \\// A seamless slice tags the low bit of capacity_or_alloc_ptr and keeps
            \\// the data pointer of the allocation it shares there.
            \\@(private = "file")
            \\roc_list_data :: proc(list: Roc_List($T)) -> rawptr {
            \\	if list.capacity_or_alloc_ptr & 1 != 0 {
            \\		return rawptr(uintptr(list.capacity_or_alloc_ptr &~ 1))
            \\	}
            \\	return list.elements
            \\}
            \\
            \\// The list takes over the references the elements hold. An empty slice
            \\// allocates nothing.
            \\@(private = "file")
            \\roc_list_from_slice_with :: proc(elems: []$T, elements_refcounted: bool) -> Roc_List(T) {
            \\	if len(elems) == 0 {
            \\		return {}
            \\	}
            \\	n := uint(len(elems))
            \\	data := roc_alloc_refcounted(n * size_of(T), align_of(T), elements_refcounted, n)
            \\	list := Roc_List(T){elements = ([^]T)(data), length = n, capacity_or_alloc_ptr = n << 1}
            \\	copy(list.elements[:n], elems)
            \\	return list
            \\}
            \\
            \\@(private = "file")
            \\roc_list_decref_flat :: proc(list: Roc_List($T)) {
            \\	data := roc_list_data(list)
            \\	if roc_release(data) {
            \\		roc_free(data, align_of(T), false)
            \\	}
            \\}
            \\
            \\// Releases the elements only when this call dropped the last reference.
            \\@(private = "file")
            \\roc_list_decref_elements :: proc(list: Roc_List($T), release: proc(value: T)) {
            \\	data := roc_list_data(list)
            \\	if !roc_release(data) {
            \\		return
            \\	}
            \\	count := list.length
            \\	if list.capacity_or_alloc_ptr & 1 != 0 {
            \\		count = (^uint)(uintptr(data) - 2 * size_of(uint))^
            \\	}
            \\	for elem in ([^]T)(data)[:count] {
            \\		release(elem)
            \\	}
            \\	roc_free(data, align_of(T), true)
            \\}
            \\
            \\
        )

## Roc's string: up to 23 bytes inline, marked by the top bit of the last byte.
str_runtime : U64, U64 -> Str
str_runtime = |size, align|
    \\Roc_Str :: struct {
    \\	bytes:                 [^]u8,
    \\	capacity_or_alloc_ptr: uint,
    \\	length:                uint,
    \\}
    \\
    \\
        .concat("#assert(size_of(Roc_Str) == ${U64.to_str(size)})\n")
        .concat("#assert(align_of(Roc_Str) == ${U64.to_str(align)})\n\n")
        .concat(
            \\// A string shorter than Roc_Str lives inline. Its last byte holds the
            \\// length with the top bit set.
            \\roc_str_from_slice :: proc(s: string) -> Roc_Str {
            \\	out: Roc_Str
            \\	n := len(s)
            \\	if n < size_of(Roc_Str) {
            \\		raw := ([^]u8)(&out)
            \\		copy(raw[:n], s)
            \\		raw[size_of(Roc_Str) - 1] = u8(n) | 0x80
            \\		return out
            \\	}
            \\	data := ([^]u8)(roc_alloc_refcounted(uint(n), 1, false, 0))
            \\	copy(data[:n], s)
            \\	return {bytes = data, capacity_or_alloc_ptr = uint(n) << 1, length = uint(n)}
            \\}
            \\
            \\roc_str_decref :: proc(s: Roc_Str) {
            \\	if int(s.length) < 0 {
            \\		return
            \\	}
            \\	data := rawptr(s.bytes)
            \\	if s.capacity_or_alloc_ptr & 1 != 0 {
            \\		data = rawptr(uintptr(s.capacity_or_alloc_ptr &~ 1))
            \\	}
            \\	if roc_release(data) {
            \\		roc_free(data, 1, false)
            \\	}
            \\}
            \\
            \\
        )

## A box is an opaque pointer. Only the Roc app can free it, because only the
## compiler knows the payload layout.
box_runtime : Str
box_runtime =
    \\roc_incref_box :: proc(box: rawptr) {
    \\	if box == nil {
    \\		return
    \\	}
    \\	rc := roc_refcount(box)
    \\	if rc^ != 0 {
    \\		rc^ += 1
    \\	}
    \\}
    \\
    \\

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

# ---------------------------------------------------------- refcount helpers

## The per-type helpers and the overload groups the host calls: `roc_decref`
## for strings and records that hold a refcounted value, and
## `roc_list_decref` and `roc_list_from_slice` for every list type.
refcount_helpers : TypeTable, List(Named), List(U64) -> Str
refcount_helpers = |table, plan, reached| {
    var $out = ""
    var $decrefs = []
    var $list_decrefs = []
    var $list_builders = []

    for type_id in reached {
        match table.get(type_id) {
            RocStr => {
                $decrefs = $decrefs.append("roc_str_decref")
            }
            _ => {}
        }
    }

    var $defined = []
    for entry in plan {
        if !$defined.contains(entry.key) {
            $defined = $defined.append(entry.key)
            if table.layout(entry.type_id).contains_refcounted {
                $out = $out.concat(record_decref(table, plan, entry))
                $decrefs = $decrefs.append(decref_name(entry.name))
            }
        }
    }

    var $lists = []
    for type_id in reached {
        match table.get(type_id) {
            RocList(elem_id) => {
                elem = odin_type(table, plan, elem_id)
                if !$lists.contains(elem) {
                    $lists = $lists.append(elem)
                    suffix = ident(elem)
                    refcounted = table.is_refcounted(elem_id)
                    body = match release_proc(table, plan, elem_id) {
                        Release(release) =>
                            if refcounted {
                                "roc_list_decref_elements(list, ${release})"
                            } else {
                                crash "OdinGlue: ${elem} has a release but is not refcounted"
                            }
                        Flat => "roc_list_decref_flat(list)"
                    }
                    flag = if refcounted { "true" } else { "false" }
                    $out = $out
                        .concat("roc_list_decref_${suffix} :: proc(list: Roc_List(${elem})) {\n\t${body}\n}\n\n")
                        .concat("roc_list_from_slice_${suffix} :: proc(elems: []${elem}) -> Roc_List(${elem}) {\n\treturn roc_list_from_slice_with(elems, ${flag})\n}\n\n")
                    $list_decrefs = $list_decrefs.append("roc_list_decref_${suffix}")
                    $list_builders = $list_builders.append("roc_list_from_slice_${suffix}")
                }
            }
            _ => {}
        }
    }

    $out
        .concat(proc_group("roc_decref", $decrefs))
        .concat(proc_group("roc_list_decref", $list_decrefs))
        .concat(proc_group("roc_list_from_slice", $list_builders))
}

## Decrefs every field that holds a refcounted value.
record_decref : TypeTable, List(Named), Named -> Str
record_decref = |table, plan, entry| {
    var $out = "${decref_name(entry.name)} :: proc(value: ${entry.name}) {\n"
    for field in table.layout(entry.type_id).record_fields() {
        if !field.is_padding {
            match release_proc(table, plan, field.type_id) {
                Release(release) => {
                    $out = $out.concat("\t${release}(value.${field.name})\n")
                }
                Flat => {}
            }
        }
    }
    $out.concat("}\n\n")
}

## The helper that releases one value of a type, or Flat when the type holds
## nothing refcounted.
release_proc : TypeTable, List(Named), U64 -> [Release(Str), Flat]
release_proc = |table, plan, type_id|
    match table.get(type_id) {
        RocStr => Release("roc_str_decref")
        RocList(elem_id) => Release("roc_list_decref_${ident(odin_type(table, plan, elem_id))}")
        RocRecord(rec) =>
            if table.layout(type_id).contains_refcounted {
                Release(decref_name(canonical(plan, rec.name)))
            } else {
                Flat
            }
        RocBox(_) => crash "OdinGlue: no decref for a Box inside a value; only the Roc app knows its payload"
        _ => Flat
    }

decref_name : Str -> Str
decref_name = |name| "${Str.with_ascii_lowercased(name)}_decref"

## An Odin spelling as a lower-case identifier suffix: Roc_List(u16) becomes
## roc_list_u16.
ident : Str -> Str
ident = |spelling| {
    open = RocName.replace_all(spelling, "(", "_")
    Str.with_ascii_lowercased(RocName.replace_all(open, ")", ""))
}

proc_group : Str, List(Str) -> Str
proc_group = |name, members| {
    if members.is_empty() {
        return ""
    }
    var $out = "${name} :: proc {\n"
    for member in members {
        $out = $out.concat("\t${member},\n")
    }
    $out.concat("}\n\n")
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
