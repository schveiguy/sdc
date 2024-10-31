module d.gc.thread;

import d.gc.capi;
import d.gc.tcache;
import d.gc.tstate;
import d.gc.types;
import d.gc.spec;

void pthreadMessage(const char* msg, size_t p) {
	import core.stdc.stdio;
	char[128] buf;
	auto len = snprintf(buf.ptr, buf.length, msg, p);
	stderrSafeMessage(buf.ptr[0 .. len]);
}

void stderrSafeMessage(const(char)[] msg) {
	import d.gc.tcache;
	char[256] buf;
	import core.stdc.unistd, core.stdc.stdio;
	auto len = snprintf(buf.ptr, buf.length, "MESSAGE %p: %.*s\n",
	                    threadCache.self, cast(int) msg.length, msg.ptr);
	write(STDERR_FILENO, buf.ptr, len);
}

void createProcess() {
	enterBusyState();
	scope(exit) exitBusyState();

	import d.gc.signal;
	setupSignals();

	initThread();

	import d.gc.hooks;
	__sd_gc_register_global_segments();

	import d.rt.elf;
	registerTlsSegments();
}

void createThread() {
	enterBusyState();
	scope(exit) {
		exitThreadCreation();
		exitBusyState();
	}

	initThread();

	import d.rt.elf;
	registerTlsSegments();
}

void destroyThread() {
	threadCache.destroyThread();
	gThreadState.remove(&threadCache);
}

void enterThreadCreation() {
	gThreadState.enterThreadCreation();
}

void exitThreadCreation() {
	gThreadState.exitThreadCreation();
}

uint getRegisteredThreadCount() {
	return gThreadState.getRegisteredThreadCount();
}

uint getSuspendedThreadCount() {
	return gThreadState.getSuspendedThreadCount();
}

uint getRunningThreadCount() {
	return gThreadState.getRunningThreadCount();
}

void enterBusyState() {
	threadCache.state.enterBusyState();
}

void exitBusyState() {
	threadCache.state.exitBusyState();
}

void stopTheWorld() {
	gThreadState.stopTheWorld();
}

void restartTheWorld() {
	gThreadState.restartTheWorld();
}

void threadScan(ScanDg scan) {
	// Scan the registered TLS segments.
	foreach (s; threadCache.tlsSegments) {
		scan(s);
	}

	import d.gc.stack;
	scanStack(scan);
}

void scanSuspendedThreads(ScanDg scan) {
	gThreadState.scanSuspendedThreads(scan);
}

private:

void initThread() {
	assert(threadCache.state.busy, "Thread is not busy!");

	import d.gc.emap, d.gc.base;
	threadCache.initialize(&gExtentMap, &gBase);
	threadCache.activateGC();

	import d.gc.global;
	gThreadState.register(&threadCache);
}

struct ThreadState {
private:
	import d.sync.atomic;
	Atomic!uint startingThreadCount;

	import d.sync.mutex;
	shared Mutex mStats;

	uint registeredThreadCount = 0;
	uint suspendedThreadCount = 0;

	Mutex mThreadList;
	ThreadRing registeredThreads;

	Mutex stopTheWorldMutex;

public:
	/**
	 * Thread management.
	 */
	void enterThreadCreation() shared {
		startingThreadCount.fetchAdd(1);
	}

	void exitThreadCreation() shared {
		auto s = startingThreadCount.fetchSub(1);
		assert(s > 0, "enterThreadCreation was not called!");
	}

	void register(ThreadCache* tcache) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).registerImpl(tcache);
	}

	void remove(ThreadCache* tcache) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).removeImpl(tcache);
	}

	auto getRegisteredThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		return (cast(ThreadState*) &this).registeredThreadCount;
	}

	auto getSuspendedThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		return (cast(ThreadState*) &this).suspendedThreadCount;
	}

	auto getRunningThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		auto state = cast(ThreadState*) &this;
		return state.registeredThreadCount - state.suspendedThreadCount;
	}

	void stopTheWorld() shared {
		import d.gc.hooks;
		__sd_gc_pre_stop_the_world_hook();

		stopTheWorldMutex.lock();

		uint count;
		while (suspendRunningThreads(count++)
			       || startingThreadCount.load() > 0) {
			import sys.posix.sched;
			sched_yield();
		}
	}

	void restartTheWorld() shared {
		while (resumeSuspendedThreads()) {
			import sys.posix.sched;
			sched_yield();
		}

		stopTheWorldMutex.unlock();

		import d.gc.hooks;
		__sd_gc_post_restart_the_world_hook();
	}

	void scanSuspendedThreads(ScanDg scan) shared {
		assert(stopTheWorldMutex.isHeld());

		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).scanSuspendedThreadsImpl(scan);
	}

private:
	void registerImpl(ThreadCache* tcache) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		{
			mStats.lock();
			scope(exit) mStats.unlock();
			registeredThreadCount++;
		}

		registeredThreads.insert(tcache);
	}

	void removeImpl(ThreadCache* tcache) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		{
			mStats.lock();
			scope(exit) mStats.unlock();
			registeredThreadCount--;
		}

		registeredThreads.remove(tcache);
	}

	bool suspendRunningThreads(uint count) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		return (cast(ThreadState*) &this).suspendRunningThreadsImpl(count);
	}

	bool suspendRunningThreadsImpl(uint count) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		bool retry = false;
		uint suspended = 0;

		auto r = registeredThreads.range;
		while (!r.empty) {
			auto tc = r.front;
			scope(success) r.popFront();

			// Make sure we do not self suspend!
			if (tc is &threadCache) {
				continue;
			}

			// If the thread isn't already stopped, we'll need to retry.
			auto ss = tc.state.suspendState;
			if (ss == SuspendState.Detached) {
				continue;
			}

			// If a thread is detached, stop trying.
			if (count > 32 && ss == SuspendState.Signaled) {
				import d.gc.proc;
				if (isDetached(tc.tid)) {
					pthreadMessage("Detaching pthread %p", tc.self);
					tc.state.detach();
					continue;
				}
			}

			suspended += ss == SuspendState.Suspended;
			retry |= ss != SuspendState.Suspended;

			// If the thread has already been signaled.
			if (ss != SuspendState.None) {
				continue;
			}

			import d.gc.signal;
			signalThreadSuspend(tc);
		}

		mStats.lock();
		scope(exit) mStats.unlock();

		suspendedThreadCount = suspended;
		return retry;
	}

	bool resumeSuspendedThreads() shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		return (cast(ThreadState*) &this).resumeSuspendedThreadsImpl();
	}

	bool resumeSuspendedThreadsImpl() {
		assert(mThreadList.isHeld(), "Mutex not held!");

		bool retry = false;
		uint suspended = 0;

		auto r = registeredThreads.range;
		while (!r.empty) {
			auto tc = r.front;
			scope(success) r.popFront();

			// If the thread isn't already resumed, we'll need to retry.
			auto ss = tc.state.suspendState;
			if (ss == SuspendState.Detached) {
				continue;
			}

			suspended += ss == SuspendState.Suspended;
			retry |= ss != SuspendState.None;

			// If the thread isn't suspended, move on.
			if (ss != SuspendState.Suspended) {
				continue;
			}

			import d.gc.signal;
			signalThreadResume(tc);
		}

		mStats.lock();
		scope(exit) mStats.unlock();

		suspendedThreadCount = suspended;
		return retry;
	}

	void scanSuspendedThreadsImpl(ScanDg scan) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		auto r = registeredThreads.range;
		while (!r.empty) {
			auto tc = r.front;
			scope(success) r.popFront();

			// If the thread isn't suspended, move on.
			auto ss = tc.state.suspendState;
			if (ss != SuspendState.Suspended && ss != SuspendState.Detached) {
				continue;
			}

			// Scan the registered TLS segments.
			foreach (s; tc.tlsSegments) {
				scan(s);
			}

			// Only suspended thread have their stack properly set.
			// For detached threads, we just hope nothing's in there.
			if (ss == SuspendState.Suspended) {
				import d.gc.range;
				scan(makeRange(tc.stackTop, tc.stackBottom));
			}
		}
	}
}

void printFullGraph() {
	// ignore any locks, we are printing this from a child process that has no other threads.
	import d.gc.global;
	import core.stdc.stdio;
	import d.gc.range;
	static void printMemoryPointers(const(void*)[] range) {
		foreach (p; range) {
			import d.gc.rtree;
			import d.gc.util;
			auto aptr = alignDown(p, PageSize);
			if (!isValidAddress(aptr))
				continue;
			auto pd = threadCache.maybeGetPageDescriptor(p);
			auto e = pd.extent;
			if (e) {
				printf(" R:%p", p);
				if (pd.isSlab()) {
					import d.gc.slab;
					auto si = SlabAllocInfo(pd, p);
					printf(" (S%d:%p)", si.slotSize, si._address);
				} else {
					ulong npages = e.npages;
					printf(" (L%lld:%p)", npages * PageSize, e.address);
				}
			} else {
				// might be a malloc pointer. Look in the list of malloc ranges.
				import d.gc.mallocrecord;
				auto rng = mallocList.getRangeFromPtr(p);
				if (rng.ptr) {
					// use a different reference character for malloc-reference
					printf(" r:%p (M%lld:%p)", p, rng.length, rng.ptr);
				}
			}
		}
	}

	// just run the global scan with a delegate to print the roots
	void printRoot(const(void*)[] r) {
		printf("Root: %p - %p (%lld)", r.ptr, r.ptr + r.length,
		       r.length * PointerSize);
		printMemoryPointers(r);
		printf("\n");
	}

	auto cycle = gState.cycle.load();
	import d.gc.emap;
	printf("GC cycle: %d, rtree nodes at: %p\n", cast(uint) cycle,
	       gExtentMap.tree.nodes.ptr);

	import d.gc.hooks;
	__sd_gc_global_scan(printRoot);

	auto emap = &threadCache.emap;

	// now print all the allocated blocks
	import d.gc.arena;
	import d.gc.block;
	static void processBlocks(ref AllBlockRing blocks, bool hasPointers) {
		for (auto r = blocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			auto bem = emap.blockLookup(block.address);
			uint i = 0;
			while (i < PagesInBlock) {
				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;
				if (e is null) {
					// probably GC metadata
					++i;
					continue;
				}

				auto npages = e.npages;
				scope(success) i += npages;
				if (e.isSlab()) {
					auto ec = pd.extentClass;
					auto sc = ec.sizeClass;

					import d.gc.sizeclass;
					ulong* bmp;
					ulong sparseMarks;
					if (ec.supportsInlineMarking) {
						if (ec.dense)
							bmp = cast(ulong*) &e.slabMetadataMarks;
						else {
							auto ecycle = e.gcWord.load();
							bmp = &sparseMarks;
							if ((ecycle & 0xff) == cycle)
								sparseMarks = ecycle >> 8;
							else
								sparseMarks = 0;
						}
					} else {
						bmp = e.outlineMarksBuffer;
					}

					import d.gc.slab;
					int slotSize = binInfos[sc].slotSize;
					foreach (idx; 0 .. e.nslots) {
						auto addr = e.address + idx * slotSize;
						int marked = (bmp[idx / 64] >> (i % 64)) & 1;
						int live = e.slabData.valueAt(idx) ? 1 : 0;
						printf("Alloc: S%d:%p V:%d M:%d", slotSize, addr, live,
						       marked);
						if (live/* && hasPointers*/)
							printMemoryPointers(makeRange(addr[0 .. slotSize]));
						printf("\n");
					}
				} else {
					import d.gc.util;
					i += modUp(e.npages, PointerInPage);
					auto ecycle = e.gcWord.load();
					auto marked = ecycle == cycle;
					auto size = e.size;
					auto addr = e.address;
					printf("Alloc: L%d:%p V:1 M:%d", size, addr, marked);
					//if(hasPointers)
					printMemoryPointers(makeRange(addr[0 .. size]));
					printf("\n");
				}
			}
		}
	}

	foreach (uint aidx; 0 .. ArenaCount) {
		auto arena = Arena.getIfInitialized(aidx);
		if (arena is null)
			continue;
		auto cp = arena.containsPointers;
		const char* isptr;
		if (cp)
			isptr = "ptr";
		else
			isptr = "noptr";
		printf("Arena %d (%s):\n", aidx, isptr);
		// go through all the blocks
		processBlocks((cast(Arena*) arena).filler.denseBlocks, cp);
		processBlocks((cast(Arena*) arena).filler.sparseBlocks, cp);
	}

	// print the malloc blocks
	import d.gc.mallocrecord;
	auto mallocRange = mallocList.getList();
	foreach (r; mallocRange) {
		printf("Malloc: %lld:%p", r.length, r.ptr);
		printMemoryPointers(makeRange(r));
		printf("\n");
	}
}

shared ThreadState gThreadState;
