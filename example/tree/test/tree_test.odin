package engine

import "core:testing"

// Run with -define:ODIN_TEST_THREADS=1: the stub allocator is global.

LONG_TEXT :: "a label longer than twenty-three bytes"

text_element :: proc(s: string) -> Roc_Element {
	element := Roc_Element{tag = .Text}
	element.payload.text = {str = roc_str_from_slice(s), size = 16}
	return element
}

box_element :: proc(children: []Roc_Element) -> Roc_Element {
	element := Roc_Element{tag = .Box}
	element.payload.box = {_0 = {gap = 4, background = 0xff00ffff}, _1 = roc_list_from_slice(children)}
	return element
}

roc_refcount_add :: proc(data: rawptr, n: int) {
	(^int)(uintptr(data) - size_of(int))^ += n
}

@(test)
test_element_is_stored_inline_with_its_tag_after_the_payload :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Roc_Element), 40)
	testing.expect_value(t, align_of(Roc_Element), 8)
	testing.expect_value(t, offset_of(Roc_Element, tag), 32)
	testing.expect_value(t, u8(Roc_Element_Tag.Box), 0)
	testing.expect_value(t, u8(Roc_Element_Tag.Text), 1)
}

@(test)
test_box_payload_puts_the_children_before_the_config :: proc(t: ^testing.T) {
	testing.expect(t, type_of(Roc_Element_Box{}._1) == Roc_List(Roc_Element))
	testing.expect_value(t, offset_of(Roc_Element_Box, _1), 0)
	testing.expect_value(t, offset_of(Roc_Element_Box, _0), 24)
}

@(test)
test_two_level_tree_frees_every_allocation :: proc(t: ^testing.T) {
	stub_reset()
	inner := box_element([]Roc_Element{text_element(LONG_TEXT), text_element("ok")})
	roots := roc_list_from_slice([]Roc_Element{box_element([]Roc_Element{text_element(LONG_TEXT), inner})})
	testing.expect_value(t, g_allocs, 5)
	roc_list_decref(roots)
	testing.expect_value(t, g_deallocs, g_allocs)
	testing.expect_value(t, len(g_blocks), 0)
	testing.expect_value(t, g_bad_frees, 0)
}

@(test)
test_shared_children_survive_until_the_last_reference :: proc(t: ^testing.T) {
	stub_reset()
	outer := box_element([]Roc_Element{text_element(LONG_TEXT)})
	children := outer.payload.box._1
	roc_refcount_add(children.elements, 1)
	roc_decref(outer)
	testing.expect_value(t, g_deallocs, 0)
	roc_list_decref(children)
	testing.expect_value(t, g_deallocs, g_allocs)
	testing.expect_value(t, g_bad_frees, 0)
}
