module d.gc.tcache;

import d.gc.base;
import d.gc.emap;
import d.gc.ring;
import d.gc.size;
import d.gc.sizeclass;
import d.gc.slab;
import d.gc.spec;
import d.gc.tbin;
import d.gc.util;

import sdc.intrinsics;

enum DefaultEventWait = 65536;

alias RNode = Node!ThreadCache;
alias RegisteredThreadRing = Ring!ThreadCache;

ThreadCache threadCache;

struct ThreadCache {
private:
	size_t allocated;
	size_t nextAllocationEvent;
	size_t deallocated;
	size_t nextDeallocationEvent;

	CachedExtentMap emap;

	/**
	 * The bins themselves.
	 * 
	 * The thread cache allocates numerous slots that it stores
	 * in bins. This ensures most allocation can be served from
	 * bins directly without requiring any kind of lock.
	 * 
	 * This also ensure that, when we take the locks, we amortize
	 * the cost of doing over numerous allocations.
	 */
	ThreadBin[ThreadBinCount] bins;
	void*[ThreadCacheSize] binBuffer;

	/**
	 * Section for fields that are unused for "regular" operations.
	 * 
	 * These fields are only necessary for infrequent operation, so we
	 * segregate them in order to get better locality on the frequently
	 * used ones.
	 */
	import d.gc.tstate;
	ThreadState state;

	import core.stdc.pthread;
	pthread_t self;

	RNode rnode;

	void* stackBottom;
	void* stackTop;
	const(void*)[][] tlsSegments;

	/**
	 * track GC runs.
	 */
	size_t nextGCRun;
	size_t lastGCTarget;
	bool enableGC;

	int nextGCRunClassOffset;
	uint consecutiveSuccessfulGCRuns;
	uint consecutiveFailedGCRuns;

	/**
	 * Bin stats and recycling mechanism.
	 */
	static assert(ThreadBinCount < ubyte.max, "Too many thread bin!");
	ubyte nextBinToRecycle;

	ThreadBinState[ThreadBinCount] binStates;

public:
	void initialize(shared(ExtentMap)* emap, shared(Base)* base,
	                bool enableGC) {
		self = pthread_self();

		disableGC = !enableGC;

		nextAllocationEvent = DefaultEventWait;
		nextDeallocationEvent = DefaultEventWait;
		nextGCRun = DefaultEventWait;

		this.emap = CachedExtentMap(emap, base);

		uint sp = 0;
		uint i = 0;

		foreach (s; 0 .. BinCount) {
			auto capacity = computeThreadBinCapacity(s);

			bins[sp++] = ThreadBin(binBuffer[i .. i + capacity]);
			i += capacity;

			bins[sp++] = ThreadBin(binBuffer[i .. i + capacity]);
			i += capacity;
		}

		// Because this may allocate, we do it last.
		import d.rt.elf;
		stackBottom = getStackBottom();
	}

	bool activateGC(bool activated = true) {
		scope(exit) enableGC = activated;
		return enableGC;
	}

	void destroyThread() {
		free(tlsSegments.ptr);
		flushCache();
	}

	void* alloc(size_t size, bool containsPointers, bool zero) {
		if (!isAllocatableSize(size)) {
			return null;
		}

		if (isSmallSize(size)) {
			return allocSmall(size, containsPointers, zero);
		}

		return allocLarge(size, containsPointers, zero);
	}

	void* allocAppendable(size_t size, bool containsPointers, bool zero,
	                      Finalizer finalizer = null) {
		// Reserve bytes for the finalizer if needed.
		auto asize = size + (finalizer !is null) * PointerSize;
		if (!isAllocatableSize(asize)) {
			return null;
		}

		asize = getAllocSize(max(asize, 2 * Quantum));
		assert(sizeClassSupportsMetadata(getSizeClass(asize)),
		       "allocAppendable got size class without metadata support!");

		if (isSmallSize(asize)) {
			auto ptr = allocSmall(asize, containsPointers, zero);
			if (unlikely(ptr is null)) {
				return null;
			}

			auto pd = getPageDescriptor(ptr);
			auto si = SlabAllocInfo(pd, ptr);
			si.initializeMetadata(finalizer, size);
			return ptr;
		}

		auto ptr = allocLarge(size, containsPointers, zero);
		if (unlikely(ptr is null)) {
			return null;
		}

		auto pd = getPageDescriptor(ptr);
		auto e = pd.extent;
		e.setUsedCapacity(size);
		e.setFinalizer(finalizer);
		return ptr;
	}

	void free(void* ptr) {
		if (ptr is null) {
			return;
		}

		auto pd = getPageDescriptor(ptr);
		free(pd, ptr);
	}

	void free(PageDescriptor pd, void* ptr) {
		if (likely(pd.isSlab())) {
			freeSmall(pd, ptr);
		} else {
			freeLarge(pd);
		}
	}

	void destroy(void* ptr) {
		if (ptr is null) {
			return;
		}

		auto pd = getPageDescriptor(ptr);
		auto e = pd.extent;

		if (likely(pd.isSlab())) {
			auto si = SlabAllocInfo(pd, ptr);
			auto finalizer = si.finalizer;
			if (finalizer !is null) {
				assert(cast(void*) si.address == ptr,
				       "destroy() was invoked on an interior pointer!");

				import d.gc.hooks;
				__sd_gc_finalize(ptr, si.usedCapacity, finalizer);
			}

			freeSmall(pd, ptr);
		} else {
			if (e.finalizer !is null) {
				import d.gc.hooks;
				__sd_gc_finalize(ptr, e.usedCapacity, e.finalizer);
			}

			freeLarge(pd);
		}
	}

	void* realloc(void* ptr, size_t size, bool containsPointers) {
		if (size == 0) {
			free(ptr);
			return null;
		}

		if (!isAllocatableSize(size)) {
			return null;
		}

		if (ptr is null) {
			return alloc(size, containsPointers, false);
		}

		auto copySize = size;
		auto pd = getPageDescriptor(ptr);

		auto ec = pd.extentClass;
		auto samePointerness = containsPointers == pd.containsPointers;

		if (ec.isSlab()) {
			auto newSizeClass = getSizeClass(size);
			auto oldSizeClass = ec.sizeClass;

			if (samePointerness && newSizeClass == oldSizeClass) {
				if (!ec.supportsMetadata) {
					return ptr;
				}

				auto si = SlabAllocInfo(pd, ptr);
				if (si.setUsedCapacity(size)) {
					return ptr;
				}
			}

			if (newSizeClass > oldSizeClass) {
				copySize = getSizeFromClass(oldSizeClass);
			}
		} else {
			auto e = pd.extent;
			if (samePointerness && size > MaxSmallSize) {
				auto epages = e.npages;
				auto npages = getPageCount(size);

				if (epages < npages) {
					if (!pd.arena.growLarge(emap, e, npages)) {
						goto LargeResizeFailed;
					}

					triggerAllocationEvent((npages - epages) * PageSize);
				} else if (epages > npages) {
					if (!pd.arena.shrinkLarge(emap, e, npages)) {
						goto LargeResizeFailed;
					}

					triggerDeallocationEvent((epages - npages) * PageSize);
				}

				e.setUsedCapacity(size);
				return ptr;
			}

		LargeResizeFailed:
			copySize = min(size, e.usedCapacity);
		}

		auto newPtr = alloc(size, containsPointers, false);
		if (newPtr is null) {
			return null;
		}

		if (!isSmallSize(size)) {
			auto npd = getPageDescriptor(newPtr);
			npd.extent.setUsedCapacity(size);
		}

		memcpy(newPtr, ptr, copySize);
		free(pd, ptr);

		return newPtr;
	}

	void flushCache() {
		state.enterBusyState();
		scope(exit) state.exitBusyState();

		foreach (ref b; bins) {
			b.fullFlush(emap);
		}
	}

private:
	/**
	 * Small allocations.
	 */
	void* allocSmall(size_t size, bool containsPointers, bool zero) {
		// TODO: in contracts
		assert(isSmallSize(size));

		import d.gc.slab;
		auto sizeClass = getSizeClass(size);
		auto slotSize = binInfos[sizeClass].slotSize;

		auto ptr = allocSmallBin(sizeClass, slotSize, containsPointers);
		if (unlikely(ptr is null)) {
			return null;
		}

		if (unlikely(zero)) {
			memset(ptr, 0, slotSize);
		} else if (containsPointers) {
			// Zero out the non-allocated part of the slot to avoid stale pointers.
			memset(ptr + size, 0, slotSize - size);
		}

		triggerAllocationEvent(slotSize);
		return ptr;
	}

	static uint getBinIndex(ubyte sizeClass, bool containsPointers) {
		return 2 * sizeClass | containsPointers;
	}

	void* allocSmallBin(ubyte sizeClass, uint slotSize, bool containsPointers) {
		assert(slotSize == binInfos[sizeClass].slotSize, "Invalid slot size!");

		auto index = getBinIndex(sizeClass, containsPointers);
		auto bin = &bins[index];

		void* ptr;
		if (likely(bin.allocate(ptr))) {
			return ptr;
		}

		// We are about to allocate, make room for it if needed.
		maybeRunGCCycle();

		// The bin is empty, refill.
		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			auto arena = chooseArena(containsPointers);
			bin.refill(emap, arena, binStates[index], sizeClass, slotSize);
		}

		if (bin.allocateEasy(ptr)) {
			return ptr;
		}

		return null;
	}

	void freeSmall(PageDescriptor pd, void* ptr) {
		assert(pd.isSlab(), "Slab expected!");

		auto ec = pd.extentClass;
		auto sc = ec.sizeClass;

		// We trigger the de-allocation event first as it might
		// recycle the bin we are interested in, which increase
		// our chances that free works.
		triggerDeallocationEvent(binInfos[sc].slotSize);

		auto index = getBinIndex(sc, pd.containsPointers);
		auto bin = &bins[index];
		if (likely(bin.free(ptr))) {
			return;
		}

		// The bin is full, make space.
		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			bin.flushToFree(emap, binStates[index]);
		}

		auto success = bin.free(ptr);
		assert(success, "Unable to free!");
	}

	/**
	 * Large allocations.
	 */
	void* allocLarge(size_t size, bool containsPointers, bool zero) {
		// We are about to allocate, make room for it if needed.
		maybeRunGCCycle();
		auto pages = getPageCount(size);
		void* ptr;

		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			auto arena = chooseArena(containsPointers);
			ptr = arena.allocLarge(emap, pages, zero);
		}

		if (unlikely(ptr is null)) {
			return null;
		}

		if (containsPointers && !zero) {
			memset(ptr + size, 0, pages * PageSize - size);
		}

		triggerAllocationEvent(pages * PageSize);
		return ptr;
	}

	void freeLarge(PageDescriptor pd) {
		assert(!pd.isSlab(), "Slab are not supported!");

		auto e = pd.extent;
		auto npages = e.npages;

		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			pd.arena.freeLarge(emap, e);
		}

		triggerDeallocationEvent(npages * PageSize);
	}

	/**
	 * Bytes accounting and bin maintenance.
	 */
	void triggerAllocationEvent(size_t bytes) {
		allocated += bytes;

		if (allocated >= nextAllocationEvent) {
			recycleNextBin();
			// check for triggering an automatic collection
			checkAutomaticCollection();

			nextAllocationEvent = allocated + DefaultEventWait;
		}
	}

	/**
	 * Check whether we should run an automatic collection, and if so, run
	 * it.
	 */
	void checkAutomaticCollection() {
		import d.gc.region;
		if (gPointerRegionAllocator.checkBlockThreshold()
			    || gDataRegionAllocator.checkBlockThreshold()) {
			this.runGCCycle();
		}
	}

	void triggerDeallocationEvent(size_t bytes) {
		deallocated += bytes;

		if (deallocated >= nextDeallocationEvent) {
			recycleNextBin();

			nextDeallocationEvent = deallocated + DefaultEventWait;
		}
	}

	void recycleNextBin() {
		auto index = nextBinToRecycle;
		ubyte sizeClass = index / 2;

		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			bins[index].recycle(emap, binStates[index], sizeClass);
		}

		nextBinToRecycle++;
		if (nextBinToRecycle >= ThreadBinCount) {
			nextBinToRecycle = 0;
		}
	}

	/**
	 * Appendable facilities.
	 */
	size_t getCapacity(const void[] slice) {
		auto pd = maybeGetPageDescriptor(slice.ptr);
		auto e = pd.extent;
		if (e is null) {
			return 0;
		}

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, slice.ptr);

			if (!validateCapacity(slice, si.address, si.usedCapacity)) {
				return 0;
			}

			auto startIndex = slice.ptr - si.address;
			return si.slotCapacity - startIndex;
		}

		if (!validateCapacity(slice, e.address, e.usedCapacity)) {
			return 0;
		}

		auto startIndex = slice.ptr - e.address;
		return e.size - startIndex;
	}

	void[] getAllocationSlice(const void* ptr) {
		auto pd = maybeGetPageDescriptor(ptr);
		auto e = pd.extent;
		if (e is null) {
			return [];
		}

		void* base;
		size_t size;

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			base = si.address;
			size = si.usedCapacity;
		} else {
			base = e.address;
			size = e.usedCapacity;
		}

		if (ptr >= base + size) {
			return [];
		}

		return base[0 .. size];
	}

	bool extend(const void[] slice, size_t size) {
		if (size == 0) {
			return true;
		}

		auto pd = maybeGetPageDescriptor(slice.ptr);
		auto e = pd.extent;

		if (e is null) {
			return false;
		}

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, slice.ptr);
			auto usedCapacity = si.usedCapacity;

			if (!validateCapacity(slice, si.address, usedCapacity)) {
				return false;
			}

			return si.setUsedCapacity(usedCapacity + size);
		}

		if (!validateCapacity(slice, e.address, e.usedCapacity)) {
			return false;
		}

		auto epages = e.npages;
		auto newCapacity = e.usedCapacity + size;

		auto npages = getPageCount(newCapacity);
		if (epages < npages) {
			if (!pd.arena.growLarge(emap, e, npages)) {
				return false;
			}

			triggerAllocationEvent((npages - epages) * PageSize);
		}

		e.setUsedCapacity(newCapacity);
		return true;
	}

	/**
	 * GC facilities
	 */
	void maybeRunGCCycle() {
		// If the GC is disabled or we have not reached the point
		// at which we try to collect, move on.
		if (!enableGC || allocated < nextGCRun) {
			return;
		}

		// Do not run GC cycles when we are busy as another thread
		// might be trying to run its own GC cycle and waiting on us.
		if (state.busy) {
			return;
		}

		size_t delta, target;

		import d.gc.collector;
		auto collector = Collector(&this);
		auto didRun = collector.maybeRunGCCycle(delta, target);

		/**
		 * Even though we now have a target, this is actually not enough
		 * to decide when to try to collect again. For instance:
		 *  - The rate at which we free allocations is unknown. If half
		 *    of what we allocate is freed, we need to wait twice as long.
		 *  - If several threads are running, they all will be checking if
		 *    collection is required on a regular basis. Each thread must
		 *    avoid checking too frequently.
		 * 
		 * These behavior depend on the application and will change at runtime.
		 * Therefore, we need to measure and adjust the frequency at which
		 * we try to collect based on the run-time behavior.
		 * 
		 * To do that, we scale the target based on size classes and adjust
		 * the size class based on historical behavior.
		 */

		// Make sure we don't blow up if target == 0.
		int targetClass = getSizeClass(max(target, 1));
		targetClass += nextGCRunClassOffset;

		int c0 = getSizeClass(lastGCTarget);
		int c1 = getSizeClass(lastGCTarget + delta);
		int offsetDelta = (c1 - c0) / 2;

		if (didRun) {
			consecutiveFailedGCRuns = 0;
			targetClass -= consecutiveSuccessfulGCRuns++;

			// We overshoot, nerf the offset.
			nextGCRunClassOffset -= offsetDelta;
		} else {
			consecutiveSuccessfulGCRuns = 0;
			targetClass += consecutiveFailedGCRuns++;

			// We undershoot, bump the offset.
			nextGCRunClassOffset += offsetDelta;
		}

		// Adjust offset and clamp the result.
		enum MaxSizeClass = getSizeClass(512 * 512);
		targetClass = min(targetClass, MaxSizeClass);
		targetClass = max(targetClass, 0);

		lastGCTarget = getSizeFromClass(targetClass);
		nextGCRun = allocated + lastGCTarget * PageSize;
		/+
		char[4096] buf;

		import core.stdc.unistd, core.stdc.stdio, core.stdc.pthread;
		auto len = snprintf(
			buf.ptr,
			buf.length,
			"[%p] GC did run: %d\tdelta: %ld\ttarget: %ld\toffsetDelta: %d\tnextOffset: %d\n",
			pthread_self(),
			didRun,
			delta,
			target,
			offsetDelta,
			nextGCRunClassOffset,
		);
		write(STDERR_FILENO, buf.ptr, len);
		// +/
	}

	/**
	 * TLS registration.
	 */
	void addTLSSegment(const void[] range) {
		auto ptr = cast(void*) tlsSegments.ptr;
		auto index = tlsSegments.length;
		auto length = index + 1;

		// We realloc every time. It doesn't really matter at this point.
		ptr = realloc(ptr, length * void*[].sizeof, true);
		tlsSegments = (cast(const(void*)[]*) ptr)[0 .. length];

		import d.gc.range;
		tlsSegments[index] = makeRange(range);
	}

private:
	/**
	 * Appendable's mechanics:
	 * 
	 *  __data__  _____free space_______
	 * /        \/                      \
	 * -----sss s....... ....... ........
	 *      \___________________________/
	 * 	           Capacity is 27
	 * 
	 * If the slice's end doesn't match the used capacity,
	 * then we return 0 in order to force a reallocation
	 * when appending:
	 * 
	 *  ___data____  ____free space_____
	 * /           \/                   \
	 * -----sss s---.... ....... ........
	 *      \___________________________/
	 * 	           Capacity is 0
	 * 
	 * See also: https://dlang.org/spec/arrays.html#capacity-reserve
	 */
	bool validateCapacity(const void[] slice, const void* address,
	                      size_t usedCapacity) {
		// Slice must not end before valid data ends, or capacity is zero.
		// To be appendable, the slice end must match the alloc's used
		// capacity, and the latter may not be zero.
		auto startIndex = slice.ptr - address;
		auto stopIndex = startIndex + slice.length;

		return stopIndex != 0 && stopIndex == usedCapacity;
	}

	auto getPageDescriptor(void* ptr) {
		auto pd = maybeGetPageDescriptor(ptr);
		assert(pd.extent !is null);
		assert(pd.isSlab() || ptr is pd.extent.address);

		return pd;
	}

	auto maybeGetPageDescriptor(const void* ptr) {
		auto aptr = alignDown(ptr, PageSize);
		return emap.lookup(aptr);
	}

	auto chooseArena(bool containsPointers) {
		/**
		 * We assume this call is cheap.
		 * This is true on modern linux with modern versions
		 * of glibc thanks to rseqs, but we might want to find
		 * an alternative on other systems.
		 */
		import sys.posix.sched;
		int cpuid = sched_getcpu();

		import d.gc.arena;
		return Arena.getOrInitialize((cpuid << 1) | containsPointers);
	}
}

private:

unittest nonAllocatableSizes {
	ThreadCache tc;

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == 0);
		assert(tc.allocated == tc.deallocated);
	}

	// Prohibited sizes of allocations
	assert(tc.alloc(0, false, false) is null);
	assert(tc.alloc(MaxAllocationSize + 1, false, false) is null);
	assert(tc.allocAppendable(0, false, false) is null);
	assert(tc.allocAppendable(MaxAllocationSize + 1, false, false) is null);
}

unittest trackAllocatedBytes {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	size_t expected = 0;

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == expected);
		assert(tc.allocated == tc.deallocated);
	}

	// Check that small allocations are accounted for.
	foreach (size; 1 .. MaxSmallSize + 1) {
		expected += getAllocSize(size);

		auto ptr0 = tc.alloc(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr0);
		assert(tc.deallocated == expected);

		expected += getAllocSize(max(size, 2 * Quantum));

		auto ptr1 = tc.allocAppendable(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr1);
		assert(tc.deallocated == expected);
	}

	// Check that large allocations are accounted for.
	for (size_t size = MaxSmallSize + 1; size < 12345; size += 97) {
		auto asize = getPageCount(size) * PageSize;
		expected += asize;

		auto ptr0 = tc.alloc(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr0);
		assert(tc.deallocated == expected);

		expected += asize;

		auto ptr1 = tc.allocAppendable(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr1);
		assert(tc.deallocated == expected);
	}
}

unittest zero {
	enum LargeSize = 5 * PageSize;
	enum SmallSize = 8;

	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	// Check that zeroing large allocations works as expected.
	void* ptr0 = null;
	auto ptr = tc.alloc(LargeSize, false, true);

	// Make sure this isn't the only allocation on the block.
	if (isAligned(ptr, BlockSize)) {
		ptr0 = ptr;
		ptr = tc.alloc(LargeSize, false, true);
	}

	void checkValue(ulong value) {
		auto x = cast(ulong*) ptr;

		foreach (_; 0 .. LargeSize / ulong.sizeof) {
			assert(*x++ == value);
		}
	}

	void setValue(ulong value) {
		auto x = cast(ulong*) ptr;

		foreach (_; 0 .. LargeSize / ulong.sizeof) {
			*x++ = value;
		}

		checkValue(value);
	}

	checkValue(0);
	setValue(0xbadc0ffee0ddf00d);

	// We free and reallocate, we should get the same dirty chunk.
	tc.free(ptr);
	assert(tc.alloc(LargeSize, false, false) is ptr);
	checkValue(0xbadc0ffee0ddf00d);

	// We free and reallocate, but asking for zeroed memory.
	tc.free(ptr);
	assert(tc.alloc(LargeSize, false, true) is ptr);
	checkValue(0);

	// Cleanup after ourselves.
	tc.free(ptr);
	tc.free(ptr0);

	// Now lets check we zero correctly small allocation.
	ptr0 = tc.alloc(SmallSize, false, true);
	ptr = tc.alloc(SmallSize, false, true);

	// Make sure we keep the slab alive?
	while (alignDown(ptr, PageSize) !is alignDown(ptr0, PageSize)) {
		auto old = ptr0;
		ptr0 = ptr;
		ptr = tc.alloc(SmallSize, false, true);
		tc.free(old);
	}

	if (isAligned(ptr, BlockSize)) {
		ptr0 = ptr;
		ptr = tc.alloc(SmallSize, false, true);
	}

	auto uptr = cast(ulong*) ptr;
	assert(*uptr == 0);

	*uptr = 0xbadc0ffee0ddf00d;
	assert(*uptr == 0xbadc0ffee0ddf00d);

	static reallocatePtr(ref ThreadCache tc, void* ptr, bool zero) {
		void* nptr;
		while (nptr !is ptr) {
			auto old = nptr;
			nptr = tc.alloc(SmallSize, false, zero);

			if (old) {
				tc.free(old);
			}
		}
	}

	// Now free and reallocate.
	tc.free(ptr);
	reallocatePtr(tc, ptr, false);
	assert(*uptr == 0xbadc0ffee0ddf00d);

	// We free and reallocate, but asking for zeroed memory.
	tc.free(ptr);
	reallocatePtr(tc, ptr, true);
	assert(*uptr == 0);

	// Cleanup after ourselves.
	tc.free(ptr);
	tc.free(ptr0);
}

unittest queryAllocInfos {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	void checkAllocationSlice(void* ptr, void* base, size_t size) {
		auto slice = tc.getAllocationSlice(ptr);
		assert(slice.ptr is base);
		assert(slice.length == size);
	}

	// Non-appendable size class 6 (56 bytes)
	auto nonAppendable = tc.alloc(50, false, false);
	scope(exit) tc.free(nonAppendable);

	assert(tc.getCapacity(nonAppendable[0 .. 0]) == 0);
	assert(tc.getCapacity(nonAppendable[0 .. 50]) == 0);
	assert(tc.getCapacity(nonAppendable[0 .. 56]) == 56);

	foreach (i; 0 .. 56) {
		checkAllocationSlice(nonAppendable + i, nonAppendable, 56);
	}

	// Capacity of any slice in space unknown to the GC is zero:
	void* nullPtr = null;
	assert(tc.getCapacity(nullPtr[0 .. 0]) == 0);
	assert(tc.getCapacity(nullPtr[0 .. 100]) == 0);
	checkAllocationSlice(nullPtr, null, 0);

	void* stackPtr = &nullPtr;
	assert(tc.getCapacity(stackPtr[0 .. 0]) == 0);
	assert(tc.getCapacity(stackPtr[0 .. 100]) == 0);
	checkAllocationSlice(stackPtr, null, 0);

	static size_t tlValue;
	void* tlPtr = &tlValue;
	assert(tc.getCapacity(tlPtr[0 .. 0]) == 0);
	assert(tc.getCapacity(tlPtr[0 .. 100]) == 0);
	checkAllocationSlice(tlPtr, null, 0);

	void* allocAppendableWithCapacity(size_t size, size_t usedCapacity) {
		auto ptr = tc.allocAppendable(size, false, false);
		assert(ptr !is null);

		auto pd = tc.getPageDescriptor(ptr);
		auto e = pd.extent;
		assert(e !is null);

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			si.setUsedCapacity(usedCapacity);

			foreach (i; usedCapacity .. si.slotCapacity) {
				checkAllocationSlice(ptr + i, null, 0);
			}
		} else {
			e.setUsedCapacity(usedCapacity);

			foreach (i; usedCapacity .. e.size) {
				checkAllocationSlice(ptr + i, null, 0);
			}
		}

		foreach (i; 0 .. usedCapacity) {
			checkAllocationSlice(ptr + i, ptr, usedCapacity);
		}

		return ptr;
	}

	// Check capacity for an appendable large GC allocation.
	auto p0 = allocAppendableWithCapacity(16384, 100);
	scope(exit) tc.free(p0);

	// p0 is appendable and has the minimum large size.
	// Capacity of segment from p0, length 100 is 16384:
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);
	assert(tc.getCapacity(p0[1 .. 100]) == 16383);
	assert(tc.getCapacity(p0[50 .. 100]) == 16334);
	assert(tc.getCapacity(p0[99 .. 100]) == 16285);
	assert(tc.getCapacity(p0[100 .. 100]) == 16284);

	// If the slice doesn't go the end of the allocated area
	// then the capacity must be 0.
	assert(tc.getCapacity(p0[0 .. 0]) == 0);
	assert(tc.getCapacity(p0[0 .. 1]) == 0);
	assert(tc.getCapacity(p0[0 .. 50]) == 0);
	assert(tc.getCapacity(p0[0 .. 99]) == 0);

	assert(tc.getCapacity(p0[0 .. 99]) == 0);
	assert(tc.getCapacity(p0[1 .. 99]) == 0);
	assert(tc.getCapacity(p0[50 .. 99]) == 0);
	assert(tc.getCapacity(p0[99 .. 99]) == 0);

	// This would almost certainly be a bug in user land,
	// but let's make sure be behave reasonably there.
	assert(tc.getCapacity(p0[0 .. 101]) == 0);
	assert(tc.getCapacity(p0[1 .. 101]) == 0);
	assert(tc.getCapacity(p0[50 .. 101]) == 0);
	assert(tc.getCapacity(p0[100 .. 101]) == 0);
	assert(tc.getCapacity(p0[101 .. 101]) == 0);

	// Check capacity for an appendable small GC allocation.
	auto p1 = allocAppendableWithCapacity(4096, 100);
	scope(exit) tc.free(p1);

	// p1 is appendable and has the minimum large size.
	// Capacity of segment from p1, length 100 is 4096:
	assert(tc.getCapacity(p1[0 .. 100]) == 4096);
	assert(tc.getCapacity(p1[1 .. 100]) == 4095);
	assert(tc.getCapacity(p1[50 .. 100]) == 4046);
	assert(tc.getCapacity(p1[99 .. 100]) == 3997);
	assert(tc.getCapacity(p1[100 .. 100]) == 3996);

	// If the slice doesn't go the end of the allocated area
	// then the capacity must be 0.
	assert(tc.getCapacity(p1[0 .. 0]) == 0);
	assert(tc.getCapacity(p1[0 .. 1]) == 0);
	assert(tc.getCapacity(p1[0 .. 50]) == 0);
	assert(tc.getCapacity(p1[0 .. 99]) == 0);

	assert(tc.getCapacity(p1[0 .. 99]) == 0);
	assert(tc.getCapacity(p1[1 .. 99]) == 0);
	assert(tc.getCapacity(p1[50 .. 99]) == 0);
	assert(tc.getCapacity(p1[99 .. 99]) == 0);

	// This would almost certainly be a bug in user land,
	// but let's make sure be behave reasonably there.
	assert(tc.getCapacity(p1[0 .. 101]) == 0);
	assert(tc.getCapacity(p1[1 .. 101]) == 0);
	assert(tc.getCapacity(p1[50 .. 101]) == 0);
	assert(tc.getCapacity(p1[100 .. 101]) == 0);
	assert(tc.getCapacity(p1[101 .. 101]) == 0);
}

unittest realloc {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);
	tc.disableGC = true;

	size_t allocated = 0;
	size_t deallocated = 0;

	void checkAllocatedByteTracking() {
		assert(tc.allocated == allocated);
		assert(tc.deallocated == deallocated);
	}

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		checkAllocatedByteTracking();
		assert(tc.allocated == tc.deallocated);
	}

	// Realloc.
	auto p0 = tc.allocAppendable(20000, false, false);
	auto asize = getPageCount(20000) * PageSize;
	allocated += asize;
	checkAllocatedByteTracking();

	assert(tc.getCapacity(p0[0 .. 19999]) == 0);
	assert(tc.getCapacity(p0[0 .. 20000]) == 20480);
	assert(tc.getCapacity(p0[0 .. 20001]) == 0);

	// Decreasing the size of the allocation
	// should adjust capacity accordingly.
	auto p1 = tc.realloc(p0, 19999, false);
	assert(p1 is p0);

	assert(tc.getCapacity(p1[0 .. 19999]) == 20480);
	assert(tc.getCapacity(p1[0 .. 20000]) == 0);
	assert(tc.getCapacity(p1[0 .. 20001]) == 0);

	// Increasing the size of the allocation increases capacity.
	auto p2 = tc.realloc(p1, 20001, false);
	assert(p2 is p1);

	assert(tc.getCapacity(p2[0 .. 19999]) == 0);
	assert(tc.getCapacity(p2[0 .. 20000]) == 0);
	assert(tc.getCapacity(p2[0 .. 20001]) == 20480);

	// This realloc happens in-place when they shrink a large alloc.
	auto p3 = tc.realloc(p2, 16000, false);
	assert(p3 is p2);
	assert(tc.getCapacity(p3[0 .. 16000]) == 16384);

	deallocated += PageSize;
	checkAllocatedByteTracking();

	// The also happen in-place when extending
	// if there is room for it in the block.
	auto p4 = tc.realloc(p3, 20000, false);
	assert(p4 is p3);
	assert(tc.getCapacity(p4[0 .. 20000]) == 20480);

	allocated += PageSize;
	checkAllocatedByteTracking();

	// Realloc from large to small size class results in new allocation.
	auto p5 = tc.realloc(p4, 100, false);
	assert(p5 !is p4);

	allocated += 112;
	deallocated += 5 * PageSize;
	checkAllocatedByteTracking();

	// Cleanup after ourselves.
	tc.free(p5);
	deallocated += 112;
	checkAllocatedByteTracking();
}

unittest extendSmall {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	// Non-appendable size class 6 (56 bytes)
	auto nonAppendable = tc.alloc(50, false, false);
	assert(tc.getCapacity(nonAppendable[0 .. 50]) == 0);
	assert(tc.allocated == 56);

	// Attempt to extend a non-appendable (always considered fully occupied)
	assert(!tc.extend(nonAppendable[50 .. 50], 1));
	assert(!tc.extend(nonAppendable[0 .. 0], 1));

	// Extend by zero is permitted even when no capacity:
	assert(tc.extend(nonAppendable[50 .. 50], 0));

	// Extend in space unknown to the GC. Can only extend by zero.
	void* nullPtr = null;
	assert(tc.extend(nullPtr[0 .. 100], 0));
	assert(!tc.extend(nullPtr[0 .. 100], 1));
	assert(!tc.extend(nullPtr[100 .. 100], 1));

	void* stackPtr = &nullPtr;
	assert(tc.extend(stackPtr[0 .. 100], 0));
	assert(!tc.extend(stackPtr[0 .. 100], 1));
	assert(!tc.extend(stackPtr[100 .. 100], 1));

	static size_t tlValue;
	void* tlPtr = &tlValue;
	assert(tc.extend(tlPtr[0 .. 100], 0));
	assert(!tc.extend(tlPtr[0 .. 100], 1));
	assert(!tc.extend(tlPtr[100 .. 100], 1));

	// Check that small appendable alloc can be extended.
	auto s0 = tc.allocAppendable(42, false, false);
	assert(tc.allocated == 104);

	assert(tc.getCapacity(s0[0 .. 42]) == 48);
	assert(tc.extend(s0[0 .. 0], 0));
	assert(!tc.extend(s0[0 .. 0], 10));
	assert(!tc.extend(s0[0 .. 41], 10));
	assert(!tc.extend(s0[1 .. 41], 10));
	assert(!tc.extend(s0[0 .. 20], 10));

	assert(!tc.extend(s0[0 .. 42], 7));
	assert(!tc.extend(s0[32 .. 42], 7));
	assert(tc.extend(s0[0 .. 42], 3));
	assert(tc.getCapacity(s0[0 .. 45]) == 48);

	// Check that there are no interference.
	auto s1 = tc.allocAppendable(42, false, false);
	assert(tc.allocated == 152);

	assert(tc.extend(s1[0 .. 42], 1));
	assert(tc.getCapacity(s1[0 .. 43]) == 48);
	assert(tc.getCapacity(s0[0 .. 45]) == 48);

	// Extend to the maximum.
	assert(tc.getCapacity(s0[0 .. 42]) == 0);
	assert(tc.extend(s0[40 .. 45], 2));
	assert(tc.getCapacity(s0[0 .. 45]) == 0);
	assert(tc.getCapacity(s0[0 .. 47]) == 48);
	assert(!tc.extend(s0[0 .. 47], 2));
	assert(tc.extend(s0[0 .. 47], 1));

	// Decreasing the size of the allocation
	// should adjust capacity accordingly.
	auto s2 = tc.realloc(s0, 42, false);
	assert(s2 is s0);
	assert(tc.getCapacity(s2[0 .. 42]) == 48);
	assert(tc.allocated == 152);

	// Increasing the size of the allocation
	// should adjust capacity too.
	auto s3 = tc.realloc(s2, 45, false);
	assert(s3 is s2);
	assert(tc.getCapacity(s3[0 .. 45]) == 48);
	assert(tc.allocated == 152);

	// Increasing the size past what's supported by
	// the size class will cause a reallocation.
	auto s4 = tc.realloc(s3, 70, false);
	assert(s4 !is s3);
	assert(tc.getCapacity(s4[0 .. 80]) == 80);
	assert(tc.allocated == 232);
	assert(tc.deallocated == 48);

	// Decreasing the size of the allocation so that
	// it drops down to a lower size class also causes
	// a reallocation.
	auto s5 = tc.realloc(s4, 60, false);
	assert(s5 !is s4);
	assert(tc.getCapacity(s5[0 .. 64]) == 64);
	assert(tc.allocated == 296);
	assert(tc.deallocated == 128);

	// Cleanup after ourselves.
	tc.free(nonAppendable);
	tc.free(s1);
	tc.free(s5);
}

unittest extendLarge {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	size_t allocated = 0;
	size_t deallocated = 0;

	void checkAllocatedByteTracking() {
		assert(tc.allocated == allocated);
		assert(tc.deallocated == deallocated);
	}

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		checkAllocatedByteTracking();
		assert(tc.allocated == tc.deallocated);
	}

	enum DeadZoneSize = getPageCount(MaxSmallSize + 1) * PageSize;

	void* allocAppendableWithCapacity(size_t size, size_t usedCapacity) {
		// Make sure we keep track of all allocations.
		scope(exit) checkAllocatedByteTracking();

		auto ptr = tc.allocAppendable(size, false, false);
		assert(ptr !is null);

		auto asize = getPageCount(size) * PageSize;
		allocated += asize + DeadZoneSize;

		// We make sure we can't resize the allocation
		// by allocating a dead zone after it.
		import d.gc.size;
		auto deadzone = tc.alloc(DeadZoneSize, false, false);
		if (deadzone !is alignUp(ptr + size, PageSize)) {
			tc.free(deadzone);
			deallocated += DeadZoneSize;

			scope(success) {
				tc.free(ptr);
				deallocated += asize;
			}

			return allocAppendableWithCapacity(size, usedCapacity);
		}

		auto pd = tc.getPageDescriptor(ptr);
		assert(pd.extent !is null);
		assert(pd.extent.isLarge());
		pd.extent.setUsedCapacity(usedCapacity);
		return ptr;
	}

	// Make an appendable alloc:
	auto p0 = allocAppendableWithCapacity(16384, 100);
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);

	// Attempt to extend valid slices with capacity 0.
	// See getCapacity tests.
	assert(tc.extend(p0[0 .. 0], 0));
	assert(!tc.extend(p0[0 .. 0], 50));
	assert(!tc.extend(p0[0 .. 99], 50));
	assert(!tc.extend(p0[1 .. 99], 50));
	assert(!tc.extend(p0[0 .. 50], 50));

	// Extend by size zero is permitted but has no effect.
	assert(tc.extend(p0[100 .. 100], 0));
	assert(tc.extend(p0[0 .. 100], 0));
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);
	assert(tc.extend(p0[50 .. 100], 0));
	assert(tc.getCapacity(p0[50 .. 100]) == 16334);

	// Attempt extend with insufficient space.
	assert(tc.getCapacity(p0[100 .. 100]) == 16284);
	assert(!tc.extend(p0[0 .. 100], 16285));
	assert(!tc.extend(p0[50 .. 100], 16285));

	// Extending to the limit succeeds.
	assert(tc.extend(p0[50 .. 100], 16284));

	// Now we're full, and can extend only by zero.
	assert(tc.extend(p0[0 .. 16384], 0));
	assert(!tc.extend(p0[0 .. 16384], 1));

	// Unless we clear the dead zone, in which case we can extend again.
	tc.free(p0 + DeadZoneSize);
	deallocated += DeadZoneSize;
	checkAllocatedByteTracking();

	assert(tc.extend(p0[0 .. 16384], 1));
	assert(tc.getCapacity(p0[0 .. 16385]) == 16384 + PageSize);

	allocated += PageSize;
	checkAllocatedByteTracking();

	// Check extensions of slices.
	auto p1 = allocAppendableWithCapacity(16384, 100);
	assert(tc.getCapacity(p1[0 .. 100]) == 16384);

	assert(tc.extend(p1[0 .. 100], 50));
	assert(tc.getCapacity(p1[100 .. 150]) == 16284);
	assert(tc.extend(p1[0 .. 150], 0));

	assert(tc.getCapacity(p1[0 .. 100]) == 0);
	assert(tc.extend(p1[0 .. 100], 0));
	assert(tc.getCapacity(p1[0 .. 150]) == 16384);

	// Extent the upper half.
	assert(tc.extend(p1[125 .. 150], 100));
	assert(tc.getCapacity(p1[150 .. 250]) == 16234);

	assert(tc.getCapacity(p1[125 .. 150]) == 0);
	assert(tc.extend(p1[125 .. 150], 0));

	assert(tc.extend(p1[125 .. 250], 0));
	assert(tc.getCapacity(p1[125 .. 250]) == 16259);
	assert(tc.getCapacity(p1[0 .. 250]) == 16384);

	// Extend at the very end of the slice.
	assert(tc.extend(p1[250 .. 250], 200));
	assert(tc.getCapacity(p1[250 .. 450]) == 16134);

	assert(tc.getCapacity(p1[0 .. 250]) == 0);
	assert(tc.getCapacity(p1[0 .. 450]) == 16384);

	// Extend up to all the available space.
	assert(tc.extend(p1[0 .. 450], 15933));
	assert(tc.getCapacity(p1[16383 .. 16383]) == 1);
	assert(tc.extend(p1[16383 .. 16383], 1));
	assert(tc.getCapacity(p1[0 .. 16384]) == 16384);

	// When full, we can't extend any more.
	assert(!tc.extend(p1[0 .. 16384], 1));
	assert(tc.extend(p1[0 .. 16384], 0));

	// De-allocate everything.
	tc.free(p0);
	deallocated += 5 * PageSize;
	checkAllocatedByteTracking();

	tc.free(p1 + DeadZoneSize);
	deallocated += DeadZoneSize;
	checkAllocatedByteTracking();

	tc.free(p1);
	deallocated += 4 * PageSize;
	checkAllocatedByteTracking();
}

unittest arraySpill {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	void setAllocationUsedCapacity(void* ptr, size_t usedCapacity) {
		assert(ptr !is null);

		auto pd = tc.getPageDescriptor(ptr);
		auto e = pd.extent;
		assert(e !is null);

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			si.setUsedCapacity(usedCapacity);
		} else {
			e.setUsedCapacity(usedCapacity);
		}
	}

	// Get two allocs of given size guaranteed to be adjacent.
	void*[2] makeTwoAdjacentAllocs(uint size) {
		void* alloc() {
			return tc.alloc(size, false, false);
		}

		void*[2] tryPair(void* a, void* b) {
			assert(a !is null);
			assert(b !is null);

			if (a + size is b) {
				return [a, b];
			}

			if (b + size is a) {
				return [b, a];
			}

			auto pair = tryPair(b, alloc());
			tc.free(a);
			return pair;
		}

		return tryPair(alloc(), alloc());
	}

	void testSpill(uint arraySize, uint[] capacities) {
		auto pair = makeTwoAdjacentAllocs(arraySize);
		void* a0 = pair[0];
		void* a1 = pair[1];
		assert(a1 == a0 + arraySize);

		void testZeroLengthSlices() {
			foreach (a0Capacity; capacities) {
				setAllocationUsedCapacity(a0, a0Capacity);
				// For all possible zero-length slices of a0:
				foreach (s; 0 .. arraySize + 1) {
					// A zero-length slice has non-zero capacity
					// if and only if it resides at the start of
					// the free space of a non-empty allocation:
					auto sliceCapacity = tc.getCapacity(a0[s .. s]);
					auto haveCapacity = sliceCapacity > 0;
					assert((s == a0Capacity && s > 0 && s < arraySize)
						== haveCapacity);

					// Capacity in non-degenerate case follows standard rule:
					assert(!haveCapacity || sliceCapacity == arraySize - s);
				}
			}
		}

		// Try it with various capacities for a1:
		foreach (a1Capacity; capacities) {
			setAllocationUsedCapacity(a1, a1Capacity);
			testZeroLengthSlices();
		}

		// Same rules apply if the space above a0 is not allocated:
		tc.free(a1);
		testZeroLengthSlices();

		tc.free(a0);
	}

	testSpill(64, [0, 1, 2, 32, 63, 64]);
	testSpill(80, [0, 1, 2, 32, 79, 80]);
	testSpill(16384, [0, 1, 2, 500, 16000, 16383, 16384]);
	testSpill(20480, [0, 1, 2, 500, 20000, 20479, 20480]);
}

unittest finalization {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase, false);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	// Faux destructor which simply records most recent kill:
	static size_t lastKilledUsedCapacity = 0;
	static void* lastKilledAddress;
	static uint destroyCount = 0;
	static void destruct(void* ptr, size_t size) {
		lastKilledUsedCapacity = size;
		lastKilledAddress = ptr;
		destroyCount++;
	}

	// Finalizers for large allocs:
	auto s0 = tc.allocAppendable(16384, false, false, &destruct);
	tc.destroy(s0);
	assert(lastKilledAddress == s0);
	assert(lastKilledUsedCapacity == 16384);

	// Destroy on non-finalized alloc is harmless:
	auto s1 = tc.allocAppendable(20000, false, false);
	auto oldDestroyCount = destroyCount;
	tc.destroy(s1);
	assert(destroyCount == oldDestroyCount);

	// Finalizers for small allocs:
	auto s2 = tc.allocAppendable(45, false, false, &destruct);
	assert(tc.getCapacity(s2[0 .. 45]) == 48);
	assert(!tc.extend(s2[0 .. 45], 4));
	assert(tc.extend(s2[0 .. 45], 3));
	assert(tc.getCapacity(s2[0 .. 48]) == 48);
	tc.destroy(s2);
	assert(lastKilledAddress == s2);
	assert(lastKilledUsedCapacity == 48);

	// Behavior of realloc() on small allocs with finalizers:
	auto s3 = tc.allocAppendable(70, false, false, &destruct);
	assert(tc.getCapacity(s3[0 .. 70]) == 72);
	auto s4 = tc.realloc(s3, 70, false);
	assert(s3 == s4);

	// This is in the same size class, but will not work in-place
	// given as finalizer occupies final 8 of the 80 bytes in the slot:
	auto s5 = tc.realloc(s4, 75, false);
	assert(s5 != s4);

	// So we end up with a new alloc, without metadata:
	assert(tc.getCapacity(s5[0 .. 80]) == 80);

	// And the finalizer has been discarded:
	oldDestroyCount = destroyCount;
	tc.destroy(s5);
	assert(destroyCount == oldDestroyCount);
}
