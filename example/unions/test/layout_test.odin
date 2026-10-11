package engine

import "core:testing"

// Run with -define:ODIN_TEST_THREADS=1: the stub allocator is global.

byte_at :: proc(value: ^$T, offset: uintptr) -> u8 {
	return ([^]u8)(value)[offset]
}

@(test)
test_tags_are_numbered_alphabetically :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(Roc_View_Mode.Idle), 0)
	testing.expect_value(t, u8(Roc_View_Mode.Jump), 1)
	testing.expect_value(t, u8(Roc_View_Mode.Walk), 2)
	testing.expect_value(t, u8(Roc_View_Shape_Tag.Cube), 0)
	testing.expect_value(t, u8(Roc_View_Shape_Tag.Sphere), 1)
}

@(test)
test_union_with_no_payloads_is_a_bare_enum :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Roc_View_Mode), 1)
}

@(test)
test_nominal_union_keeps_its_name :: proc(t: ^testing.T) {
	testing.expect(t, type_of(Roc_View{}.phase) == Roc_Phase)
	testing.expect_value(t, u8(Roc_Phase.Night), 1)
}

@(test)
test_single_payload_sits_at_offset_zero :: proc(t: ^testing.T) {
	shape := Roc_View_Shape {
		tag = .Sphere,
	}
	shape.payload.sphere = 2.5
	testing.expect_value(t, (^f32)(&shape)^, 2.5)
	testing.expect_value(t, byte_at(&shape, 12), 1)

	shape = {
		tag = .Cube,
	}
	shape.payload.cube = {x = 1, y = 2, z = 3}
	testing.expect_value(t, ([^]f32)(&shape)[2], 3)
	testing.expect_value(t, byte_at(&shape, 12), 0)
}

@(test)
test_multi_field_payload_is_in_alignment_order :: proc(t: ^testing.T) {
	ray := Roc_View_Ray {
		tag = .Hit,
	}
	ray.payload.hit = {_0 = 7, _1 = 0.5, _2 = 300}
	testing.expect_value(t, (^f64)(&ray)^, 0.5)
	testing.expect_value(t, (^u16)(uintptr(&ray) + 8)^, 300)
	testing.expect_value(t, byte_at(&ray, 10), 7)
	testing.expect_value(t, byte_at(&ray, 16), 0)
}

@(test)
test_nested_union_keeps_both_tags :: proc(t: ^testing.T) {
	nested := Roc_View_Nested {
		tag = .Pick,
	}
	nested.payload.pick = {
		tag = .Small,
	}
	nested.payload.pick.payload.small = 9
	testing.expect_value(t, byte_at(&nested, 0), 9)
	testing.expect_value(t, byte_at(&nested, 4), 1)
	testing.expect_value(t, byte_at(&nested, 8), 0)
}

@(test)
test_union_in_a_record :: proc(t: ^testing.T) {
	body := Roc_View_Body {
		kind = {tag = .Soft},
		mass = 3,
	}
	body.kind.payload.soft = 0.25
	testing.expect_value(t, (^f32)(&body)^, 0.25)
	testing.expect_value(t, byte_at(&body, 4), 1)
}

@(test)
test_union_in_a_list_is_flat :: proc(t: ^testing.T) {
	stub_reset()
	items := []Roc_View_Items{{tag = .Key}, {tag = .Coin}}
	list := roc_list_from_slice(items)
	testing.expect_value(t, list.elements[0].tag, Roc_View_Items_Tag.Key)
	testing.expect_value(t, g_blocks[rawptr(uintptr(list.elements) - 8)], Block{8 + 2 * 8, 8})
	roc_list_decref(list)
	testing.expect_value(t, g_deallocs, g_allocs)
	testing.expect_value(t, g_bad_frees, 0)
}
