package mem_virtual

import "core:mem"

Growing_Arena :: struct {
	curr_block:      ^Memory_Block,
	total_used:      int,
	total_allocated: int,
	
	minimum_block_size: int,
	temp_count: int,
}

DEFAULT_MINIMUM_BLOCK_SIZE :: 1024*1024 // 1 KiB should be enough
DEFAULT_PAGE_SIZE := 4096

growing_arena_alloc :: proc(arena: ^Growing_Arena, min_size: int, alignment: int) -> (data: []byte, err: mem.Allocator_Error) {
	align_forward_offset :: proc(arena: ^Growing_Arena, alignment: int) -> int #no_bounds_check {
		alignment_offset := 0
		ptr := uintptr(arena.curr_block.base[arena.curr_block.used:])
		mask := uintptr(alignment-1)
		if ptr & mask != 0 {
			alignment_offset = alignment - int(ptr & mask)
		}
		return alignment_offset
	}
	
	assert(mem.is_power_of_two(uintptr(alignment)))
	

	size := 0
	if arena.curr_block != nil {
		size = min_size + align_forward_offset(arena, alignment)
	}
	
	if arena.curr_block == nil || arena.curr_block.used + size > arena.curr_block.size {
		size = mem.align_forward_int(min_size, alignment)
		arena.minimum_block_size = max(DEFAULT_MINIMUM_BLOCK_SIZE, arena.minimum_block_size)
		
		block_size := max(size, arena.minimum_block_size)
		
		new_block := memory_alloc(block_size) or_return
		new_block.prev = arena.curr_block
		arena.curr_block = new_block
		arena.total_allocated += new_block.size
	}
	
	curr_block := arena.curr_block
	assert(curr_block.used + size <= curr_block.size)
	
	ptr := curr_block.base[curr_block.used:]
	ptr = ptr[uintptr(align_forward_offset(arena, alignment)):]
	
	curr_block.used += size
	assert(curr_block.used <= curr_block.size)
	arena.total_used += size
	
	return ptr[:min_size], nil
}

growing_arena_free_last_memory_block :: proc(arena: ^Growing_Arena) {
	free_block := arena.curr_block
	arena.curr_block = free_block.prev
	memory_dealloc(free_block)
}

growing_arena_free_all :: proc(arena: ^Growing_Arena) {
	for arena.curr_block != nil {
		growing_arena_free_last_memory_block(arena)
	}
	arena.total_used = 0
}

growing_arena_bootstrap_new_by_offset :: proc($T: typeid, offset_to_arena: uintptr, minimum_block_size := DEFAULT_MINIMUM_BLOCK_SIZE) -> (ptr: ^T, err: mem.Allocator_Error) {
	bootstrap: Growing_Arena
	bootstrap.minimum_block_size = minimum_block_size
	
	data := growing_arena_alloc(&bootstrap, size_of(T), align_of(T)) or_return
	
	ptr = (^T)(raw_data(data))
	
	(^Growing_Arena)(uintptr(ptr) + offset_to_arena)^ = bootstrap
	
	return
}

growing_arena_bootstrap_new_by_name :: proc($T: typeid, $field_name: string, minimum_block_size := DEFAULT_MINIMUM_BLOCK_SIZE) -> (ptr: ^T, err: mem.Allocator_Error) { 
	return growing_arena_bootstrap_new_by_offset(T, offset_of_by_string(T, field_name), minimum_block_size)
}
growing_arena_bootstrap_new :: proc{
	growing_arena_bootstrap_new_by_offset, 
	growing_arena_bootstrap_new_by_name,
}

growing_arena_allocator :: proc(arena: ^Growing_Arena) -> mem.Allocator {
	return mem.Allocator{growing_arena_allocator_proc, arena}
}

growing_arena_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                             size, alignment: int,
                             old_memory: rawptr, old_size: int,
                             location := #caller_location) -> (data: []byte, err: mem.Allocator_Error) {
	arena := (^Growing_Arena)(allocator_data)
	
	switch mode {
	case .Alloc:
		return growing_arena_alloc(arena, size, alignment)
	case .Free:
		err = .Mode_Not_Implemented
		return
	case .Free_All:
		growing_arena_free_all(arena)
		return
	case .Resize:
		return mem.default_resize_bytes_align(mem.byte_slice(old_memory, old_size), size, alignment, growing_arena_allocator(arena), location)
		
	case .Query_Features, .Query_Info:
		err = .Mode_Not_Implemented
		return	
	}	
	
	err = .Mode_Not_Implemented
	return 
}

Growing_Arena_Temp :: struct {
	arena: ^Growing_Arena,
	block: ^Memory_Block,
	used:  int,
}

growing_arena_temp_begin :: proc(arena: ^Growing_Arena) -> (temp: Growing_Arena_Temp) {
	temp.arena = arena
	temp.block = arena.curr_block
	if arena.curr_block != nil {
		temp.used = arena.curr_block.used
	}
	arena.temp_count += 1
	return
}

growing_arena_temp_end :: proc(temp: Growing_Arena_Temp, loc := #caller_location) {
	assert(temp.arena != nil, "nil arena", loc)
	arena := temp.arena
	
	for arena.curr_block != temp.block {
		growing_arena_free_last_memory_block(arena)
	}
	
	if block := arena.curr_block; block != nil {
		
		assert(block.used >= temp.used, "out of order use of growing_arena_temp_end", loc)
		amount_to_zero := min(block.used-temp.used, block.size-block.used)
		
		block.used = temp.used
		
		mem.zero_slice(block.base[block.used:][:amount_to_zero])
	}
	
	assert(arena.temp_count > 0, "double-use of growing_arena_temp_end", loc)
	arena.temp_count -= 1
}

growing_arena_check_temp :: proc(arena: ^Growing_Arena, loc := #caller_location) {
	assert(condition = arena.temp_count == 0, loc = loc)
}