module dmd.gc;

import d.gc.tcache;
import d.gc.spec;
import d.gc.slab;
import d.gc.emap;

extern(C):

void __sd_gc_init() {
	import d.gc.thread;
	createProcess();
}

// Some of the bits from druntime.
enum BlkAttr : uint {
	FINALIZE = 0b0000_0001,
	NO_SCAN = 0b0000_0010,
	APPENDABLE = 0b0000_1000
}

// ptr: the pointer to query
// base: => the true base address of the block
// size: => the full usable size of the block
// pd: => the page descriptor (used internally later)
// flags: => what the flags of the block are
//
bool __sd_gc_fetch_alloc_info(void* ptr, void** base, size_t* size,
                              PageDescriptor* pd, BlkAttr* flags) {
	*pd = threadCache.maybeGetPageDescriptor(ptr);
	auto e = pd.extent;
	*flags = cast(BlkAttr) 0;
	if (!e) {
		return false;
	}

	if (!pd.containsPointers) {
		*flags |= BlkAttr.NO_SCAN;
	}

	if (pd.isSlab()) {
		auto si = SlabAllocInfo(*pd, ptr);
		*base = cast(void*) si.address;

		if (si.hasMetadata) {
			*flags |= BlkAttr.APPENDABLE;
			if (si.finalizer) {
				*flags |= BlkAttr.FINALIZE;
			}
		}

		*size = si.slotCapacity;
	} else {
		// Large blocks are always appendable.
		*flags |= BlkAttr.APPENDABLE;

		if (e.finalizer) {
			*flags |= BlkAttr.FINALIZE;
		}

		auto e = pd.extent;
		*base = e.address;

		*size = e.size;
	}

	return true;
}

bool __sd_gc_set_array_used(void* ptr, size_t newUsed, size_t existingUsed) {
	// Note: we do not allow filling completely an allocation, for it might
	// result in incorrect cross-pointing of allocations.
	auto pd = threadCache.maybeGetPageDescriptor(ptr);
	auto e = pd.extent;
	if (!e) {
		return false;
	}

	if (pd.isSlab()) {
		auto si = SlabAllocInfo(pd, ptr);
		auto offset = ptr - si.address;
		if (existingUsed < size_t.max && existingUsed + offset != si.usedCapacity) {
			// The existing capacity doesn't match.
			return false;
		}

		newUsed += offset;
		if(!si.finalizerEnabled && newUsed >= si.slotCapacity) {
			// would fill up the block, don't allow it
			return false;
		}
		return si.setUsedCapacity(newUsed);
	}

	// Large allocation.
	// We always add 1 byte to the request to avoid cross-page pointers.
	newUsed += ptr - e.address + 1;
	if (existingUsed == size_t.max) {
		existingUsed = e.usedCapacity;
	} else {
		existingUsed += ptr - e.address + 1;
		if(existingUsed != e.usedCapacity) {
			return false;
		}
	}

	if(newUsed > existingUsed) {
		return threadCache.extend(e.address[0 .. existingUsed], newUsed - existingUsed);
	}
	e.setUsedCapacity(newUsed);
	return true;
}

size_t __sd_gc_ensure_capacity(void* ptr, size_t request, size_t existingUsed) {
	import core.stdc.stdio;
	auto pd = threadCache.maybeGetPageDescriptor(ptr);
	auto e = pd.extent;
	if (!e) {
		return 0;
	}

	if (pd.isSlab()) {
		auto si = SlabAllocInfo(pd, ptr);
		auto offset = ptr - si.address;
		//printf("si = %p sz:%ld used:%ld ptr:%p req:%ld existingUsed:%ld offset:%ld\n", si.address, si.slotCapacity, si.usedCapacity, ptr, request, existingUsed, offset);
		if (existingUsed < size_t.max && existingUsed + offset != si.usedCapacity) {
			// The existing used capacity doesn't match.
			return 0;
		}

		request += offset;
		auto cap = si.slotCapacity - 1;
		if(request > cap)
			return 0;
		return cap - offset;
	}

	// Large allocation.
	// We always add 1 byte to the request to avoid cross-page pointers.
	auto offset = ptr - e.address;
	request += offset + 1;
	if (existingUsed == size_t.max) {
		existingUsed = e.usedCapacity;
	} else {
		existingUsed += offset + 1;
		if(existingUsed != e.usedCapacity) {
			return 0;
		}
	}

	if(request > e.size) {
		if(threadCache.reserve(e.address[0 .. existingUsed], request - existingUsed)) {
			return e.size - 1 - offset;
		}
		return 0;
	}
	return e.size - 1 - offset;
}

void[] __sd_gc_get_allocation_slice(const void* ptr) {
	return threadCache.getAllocationSlice(ptr);
}

void* __sd_gc_alloc_from_druntime(size_t size, uint flags, void* finalizer) {
	// determine what to do based on the bits and the size.
	bool containsPointers = (flags & BlkAttr.NO_SCAN) == 0;
	if((flags & BlkAttr.APPENDABLE) != 0) {
		// might need to add a buffer byte.
		auto bufferByte = (size >= 14336 || !(flags & BlkAttr.FINALIZE)) ? 1 : 0;
		auto ptr = threadCache.allocAppendable(size + bufferByte, containsPointers, false, finalizer);
		if(bufferByte) {
			// set allocated size down one
			auto pd = threadCache.getPageDescriptor(ptr);
			if (pd.isSlab()) {
				auto si = SlabAllocInfo(pd, ptr);
				si.setUsedCapacity(size);
			} else {
				auto e = pd.extent;
				e.setUsedCapacity(size);
			}
		}
		return ptr;
	} else {
		return threadCache.alloc(size, containsPointers, false);
	}
}

