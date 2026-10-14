package engine

import "core:testing"

// Run with -define:ODIN_TEST_THREADS=1: the stub allocator is global.

LONG_NAME :: "a name longer than twenty-three bytes"

expect_all_freed :: proc(t: ^testing.T) {
	testing.expect_value(t, g_deallocs, g_allocs)
	testing.expect_value(t, len(g_blocks), 0)
	testing.expect_value(t, g_bad_frees, 0)
}

@(test)
test_list_of_unions_with_a_refcounted_payload_frees_each_payload :: proc(t: ^testing.T) {
	stub_reset()
	load := Roc_View_Orders{tag = .Load}
	load.payload.load = {
		pack   = roc_str_from_slice(LONG_NAME),
		assets = roc_list_from_slice([]Roc_Str{roc_str_from_slice(LONG_NAME), roc_str_from_slice("cube")}),
	}
	list := roc_list_from_slice([]Roc_View_Orders{{tag = .Quit}, load})
	testing.expect_value(t, g_blocks[rawptr(uintptr(list.elements) - 16)].size, 16 + 2 * size_of(Roc_View_Orders))
	roc_list_decref(list)
	expect_all_freed(t)
}

@(test)
test_union_decref_skips_a_tag_with_no_refcounted_payload :: proc(t: ^testing.T) {
	stub_reset()
	roc_decref(Roc_View_Orders{tag = .Quit})
	roc_decref(Roc_View_Label{tag = .Unnamed})
	testing.expect_value(t, g_deallocs, 0)
	testing.expect_value(t, g_bad_frees, 0)
}

@(test)
test_multi_field_payload_frees_its_refcounted_field :: proc(t: ^testing.T) {
	stub_reset()
	label := Roc_View_Label{tag = .Named}
	label.payload.named = {_0 = roc_str_from_slice(LONG_NAME), _1 = 3}
	roc_decref(label)
	expect_all_freed(t)
}

@(test)
test_single_tag_union_frees_its_payload :: proc(t: ^testing.T) {
	stub_reset()
	roc_decref(Roc_View_Say{say = roc_str_from_slice(LONG_NAME)})
	expect_all_freed(t)
}
