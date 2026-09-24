package engine

import "base:runtime"

// The generated helpers call roc_alloc and roc_dealloc by name, as a real
// host defines them. This stub records every block so the tests can check
// that each free matches an allocation, with the same alignment.

Block :: struct {
	size:      uint,
	alignment: uint,
}

g_blocks: map[rawptr]Block
g_allocs: int
g_deallocs: int
g_bad_frees: int

roc_alloc :: proc "c" (length: uint, alignment: uint) -> rawptr {
	context = runtime.default_context()
	ptr, err := runtime.mem_alloc_non_zeroed(int(length), int(alignment))
	if err != nil {
		return nil
	}
	g_allocs += 1
	g_blocks[raw_data(ptr)] = {length, alignment}
	return raw_data(ptr)
}

roc_dealloc :: proc "c" (ptr: rawptr, alignment: uint) {
	context = runtime.default_context()
	block, ok := g_blocks[ptr]
	if !ok || block.alignment != alignment {
		g_bad_frees += 1
		return
	}
	g_deallocs += 1
	delete_key(&g_blocks, ptr)
	runtime.mem_free_with_size(ptr, int(block.size))
}

stub_reset :: proc() {
	clear(&g_blocks)
	g_allocs = 0
	g_deallocs = 0
	g_bad_frees = 0
}
