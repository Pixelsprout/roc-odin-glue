package engine

import "core:testing"

// Run with -define:ODIN_TEST_THREADS=1: the stub allocator is global.

refcount_of :: proc(data: rawptr) -> int {
	return (^int)(uintptr(data) - size_of(int))^
}

big_name :: "a name longer than twenty-three bytes"

expect_clean :: proc(t: ^testing.T) {
	testing.expect_value(t, g_deallocs, g_allocs)
	testing.expect_value(t, len(g_blocks), 0)
	testing.expect_value(t, g_bad_frees, 0)
}

@(test)
test_small_str_is_inline :: proc(t: ^testing.T) {
	stub_reset()
	s := roc_str_from_slice("cube")
	testing.expect_value(t, g_allocs, 0)
	raw := ([^]u8)(&s)
	testing.expect_value(t, string(raw[:4]), "cube")
	testing.expect_value(t, raw[size_of(Roc_Str) - 1], 0x84)
	testing.expect(t, int(s.length) < 0)
	roc_decref(s)
	testing.expect_value(t, g_deallocs, 0)
}

@(test)
test_23_byte_str_is_inline :: proc(t: ^testing.T) {
	stub_reset()
	s := roc_str_from_slice("abcdefghijklmnopqrstuvw")
	testing.expect_value(t, g_allocs, 0)
	testing.expect_value(t, ([^]u8)(&s)[23], 0x80 | 23)
}

@(test)
test_big_str_allocates_with_refcount_one :: proc(t: ^testing.T) {
	stub_reset()
	s := roc_str_from_slice(big_name)
	testing.expect_value(t, g_allocs, 1)
	testing.expect_value(t, string(s.bytes[:s.length]), big_name)
	testing.expect_value(t, s.capacity_or_alloc_ptr, uint(len(big_name)) << 1)
	testing.expect_value(t, refcount_of(s.bytes), 1)
	block := g_blocks[rawptr(uintptr(s.bytes) - 8)]
	testing.expect_value(t, block, Block{uint(8 + len(big_name)), 8})
	roc_decref(s)
	expect_clean(t)
}

@(test)
test_empty_list_allocates_nothing :: proc(t: ^testing.T) {
	stub_reset()
	list := roc_list_from_slice([]u16{})
	testing.expect_value(t, list, Roc_List(u16){})
	roc_list_decref(list)
	testing.expect_value(t, g_allocs, 0)
	testing.expect_value(t, g_deallocs, 0)
}

@(test)
test_flat_list_has_an_8_byte_header :: proc(t: ^testing.T) {
	stub_reset()
	keys := []u16{87, 65}
	list := roc_list_from_slice(keys)
	testing.expect_value(t, list.length, 2)
	testing.expect_value(t, list.capacity_or_alloc_ptr, 4)
	testing.expect_value(t, list.elements[1], 65)
	testing.expect_value(t, refcount_of(list.elements), 1)
	testing.expect_value(t, g_blocks[rawptr(uintptr(list.elements) - 8)], Block{8 + 4, 8})
	roc_list_decref(list)
	expect_clean(t)
}

@(test)
test_list_of_records_with_str_has_a_16_byte_header :: proc(t: ^testing.T) {
	stub_reset()
	meshes := []Roc_Init_Arg0_Meshes{{name = roc_str_from_slice(big_name), id = 1}, {name = roc_str_from_slice("cube"), id = 2}}
	list := roc_list_from_slice(meshes)
	testing.expect_value(t, g_allocs, 2)
	testing.expect_value(t, (^uint)(uintptr(list.elements) - 16)^, 2)
	testing.expect_value(t, g_blocks[rawptr(uintptr(list.elements) - 16)], Block{16 + 2 * size_of(Roc_Init_Arg0_Meshes), 8})
	roc_decref(Roc_Init_Arg0{seed = 7, meshes = list})
	expect_clean(t)
}

@(test)
test_shared_list_keeps_its_elements :: proc(t: ^testing.T) {
	stub_reset()
	list := roc_list_from_slice([]Roc_Init_Arg0_Meshes{{name = roc_str_from_slice(big_name), id = 1}})
	(^int)(uintptr(list.elements) - 8)^ = 2
	roc_list_decref(list)
	testing.expect_value(t, g_deallocs, 0)
	testing.expect_value(t, refcount_of(list.elements), 1)
	roc_list_decref(list)
	expect_clean(t)
}

@(test)
test_static_data_is_never_freed :: proc(t: ^testing.T) {
	stub_reset()
	list := roc_list_from_slice([]u16{1})
	(^int)(uintptr(list.elements) - 8)^ = 0
	roc_list_decref(list)
	testing.expect_value(t, g_deallocs, 0)
	(^int)(uintptr(list.elements) - 8)^ = 1
	roc_list_decref(list)
	expect_clean(t)
}

@(test)
test_seamless_slice_frees_the_backing_allocation :: proc(t: ^testing.T) {
	stub_reset()
	backing := roc_list_from_slice([]Roc_Init_Arg0_Meshes{{name = roc_str_from_slice(big_name), id = 1}, {name = roc_str_from_slice(big_name), id = 2}})
	slice := Roc_List(Roc_Init_Arg0_Meshes) {
		elements              = backing.elements[1:],
		length                = 1,
		capacity_or_alloc_ptr = uint(uintptr(backing.elements)) | 1,
	}
	roc_list_decref(slice)
	expect_clean(t)
}

@(test)
test_scene_decref_frees_the_draws :: proc(t: ^testing.T) {
	stub_reset()
	draws := roc_list_from_slice([]Roc_View_Draws{{id = 1}, {id = 2}})
	roc_decref(Roc_View{draws = draws})
	expect_clean(t)
}

@(test)
test_input_decref_frees_both_key_lists :: proc(t: ^testing.T) {
	stub_reset()
	input := Roc_Step_Arg1 {
		held    = roc_list_from_slice([]u16{87}),
		pressed = roc_list_from_slice([]u16{32}),
	}
	roc_decref(input)
	expect_clean(t)
}

@(test)
test_incref_box :: proc(t: ^testing.T) {
	stub_reset()
	storage: [2]int
	storage[0] = 1
	box := rawptr(&storage[1])
	roc_incref_box(box)
	testing.expect_value(t, storage[0], 2)
	storage[0] = 0
	roc_incref_box(box)
	testing.expect_value(t, storage[0], 0)
	roc_incref_box(nil)
}
