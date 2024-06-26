module d.sync.mutex;

import d.sync.waiter;

import sdc.intrinsics;

import sys.posix.sched;

struct Mutex {
private:
	import d.sync.atomic;
	Atomic!size_t word;

	enum size_t LockBit = 0x01;
	enum size_t QueueLockBit = 0x02;
	enum size_t ThreadDataMask = ~(LockBit | QueueLockBit);

public:
	void lock() shared {
		// No operation done after the lock is taken can be reordered before.
		size_t expected = 0;
		if (likely(word.casWeak(expected, LockBit, MemoryOrder.Acquire))) {
			return;
		}

		lockSlow();
	}

	bool tryLock() shared {
		size_t current = 0;
		if (likely(word.casWeak(current, LockBit, MemoryOrder.Acquire))) {
			return true;
		}

		if (current & LockBit) {
			return false;
		}

		assert(!(current & QueueLockBit), "Queue lock held while unlocked!");
		return word.casWeak(current, current | LockBit, MemoryOrder.Acquire);
	}

	bool isHeld() {
		return (cast(shared(Mutex)*) &this).isHeld();
	}

	bool isHeld() shared {
		return (word.load() & LockBit) != 0;
	}

	void unlock() shared {
		// No operation done before the lock is freed can be reordered after.
		size_t expected = LockBit;
		if (likely(word.casWeak(expected, 0, MemoryOrder.Release))) {
			return;
		}

		unlockSlow(Fairness.Unfair);
	}

	void unlockFairly() shared {
		// No operation done before the lock is freed can be reordered after.
		size_t expected = LockBit;
		if (likely(word.casWeak(expected, 0, MemoryOrder.Release))) {
			return;
		}

		unlockSlow(Fairness.Fair);
	}

	bool waitFor(bool delegate() condition) shared {
		assert((&this).isHeld(), "Mutex not held!");

		while (true) {
			if (condition()) {
				return true;
			}

			// FIXME: In case of timeout, we want to return false.
			//        At the moment, timeouts are not supported.
			unlockAndWait();
		}
	}

private:
	enum Handoff {
		None,
		Barging,
		Direct,
	}

	/**
	 * When the lock is contended, we create a linked list
	 * representing the threads waiting on the lock.
	 *
	 * The linked list loops around (the tail points to the head)
	 * and the mutex itself points ot the tail, such as
	 * tail.next == head.
	 */
	struct ThreadData {
		// Covered by the queue lock.
		ThreadData* next;

	shared: // FIXME: shared colon block aparently isn't working.
		shared Waiter waiter;
		shared Atomic!uint handoff;
	}

	static ThreadData threadData;

	void lockSlow() shared {
		// Trusting WTF::WordLock on that one...
		enum SpinLimit = 40;
		uint spinCount = 0;

		while (true) {
			auto current = word.load(MemoryOrder.Relaxed);

			// If the lock if free, we try to barge in.
			if (!(current & LockBit)) {
				assert(!(current & QueueLockBit),
				       "Queue lock held while unlocked!");

				if (word.casWeak(current, current | LockBit,
				                 MemoryOrder.Acquire)) {
					// We got the lock, VICTORY !
					return;
				}

				continue;
			}

			assert(current & LockBit, "Lock not held!");

			// If nobody's parked...
			if (!(current & ThreadDataMask) && spinCount < SpinLimit) {
				spinCount++;
				sched_yield();
				continue;
			}

			// Add ourselves in the queue.
			auto me = &threadData;
			assert(me.next is null, "This thread is already queued!");

			// Make sure we are setup for handoff.
			assert(me.handoff.load() == Handoff.None, "Invalid handoff state!");

			// If we can, try try to register atomically.
			if (current == LockBit) {
				me.next = me;
				if (word.casWeak(current, LockBit | cast(size_t) me,
				                 MemoryOrder.Release)) {
					goto Handoff;
				}

				me.next = null;
				continue;
			}

			// We cannot register atomically, take the queue lock.
			if ((current & QueueLockBit) || !word
				    .casWeak(current, current | QueueLockBit,
				             MemoryOrder.Acquire)) {
				sched_yield();
				continue;
			}

			static enqueue(size_t current, ThreadData* me) {
				auto tail = cast(ThreadData*) (current & ThreadDataMask);
				assert(tail !is null,
				       "Failed to short circuit on empty queue!");

				me.next = tail.next;
				tail.next = me;

				return cast(size_t) me;
			}

			// Now we store the updated head. Note that this will release the
			// queue lock too, but it's okay, by now we are in the queue.
			word.store(LockBit | enqueue(current, me), MemoryOrder.Release);

		Handoff:
			if (waitForHandoff() == Handoff.Direct) {
				assert((&this).isHeld(), "Lock not held!");
				return;
			}
		}
	}

	static uint waitForHandoff() {
		auto me = &threadData;

		// Wait for the control to be handed back to us.
		uint handoff;
		while ((handoff = me.handoff.load(MemoryOrder.Acquire))
			       == Handoff.None) {
			me.waiter.block();

			// FIXME: Dequeue ourselves in case of timeout.
		}

		// Setup ourselves up for the next handoff.
		me.handoff.store(Handoff.None, MemoryOrder.Release);

		assert(handoff == Handoff.Direct || handoff == Handoff.Barging,
		       "Invalid handoff value!");
		return handoff;
	}

	// FIXME: Crashing for some reason.
	enum Fairness /* : bool */ {
		Unfair = 0,
		Fair = 1,
	}

	void unlockSlow(Fairness fair) shared {
		unlockSlowImpl!false(fair);
	}

	void unlockAndWait() shared {
		unlockSlowImpl!true(Fairness.Unfair);

		if (waitForHandoff() == Handoff.Barging) {
			lock();
		}

		assert((&this).isHeld(), "Lock not held!");
	}

	void unlockSlowImpl(bool QueueMe)(Fairness fair) shared {
		size_t fastUnlock = 0;
		static if (QueueMe) {
			auto me = &threadData;
			assert(me.next is null, "This thread is already queued!");

			me.next = me;
			fastUnlock = cast(size_t) me;
		}

		while (true) {
			auto current = word.load(MemoryOrder.Relaxed);
			assert(current & LockBit, "Lock not held!");

			// If nobody is parked, just unlock.
			if (current == LockBit) {
				if (word.casWeak(current, fastUnlock, MemoryOrder.Release)) {
					return;
				}

				continue;
			}

			// If the queue is locked, just wait.
			if (current & QueueLockBit) {
				sched_yield();
				continue;
			}

			// We must have another thread waiting. Lock the queue
			// and release the next thread in line.
			if (word.casWeak(current, current | QueueLockBit,
			                 MemoryOrder.Acquire)) {
				break;
			}
		}

		auto current = word.load(MemoryOrder.Relaxed);
		assert(current & LockBit, "Lock not held!");
		assert(current & QueueLockBit, "Queue lock not held!");

		auto tail = cast(ThreadData*) (current & ThreadDataMask);
		assert(tail !is null, "Failed to short circuit on empty queue!");

		/**
		 * FIXME: We might end up running through the same conditions
		 *        again and again with that strategy. A better approach
		 *        would be to make sure we dequeu at least one non condition
		 *        thread if there is one, maybe?
		 */
		// Pop the head and queue this thread if requested.
		auto head = tail.next;

		static if (QueueMe) {
			tail.next = me;
			me.next = head.next;

			auto newTail = me;
		} else {
			tail.next = head.next;

			auto newTail = (head is tail) ? null : tail;
		}

		/**
		 * As we update the tail, we also release the queue lock.
		 * The lock itself is kept is the fair case, or unlocked if
		 * fairness is not a concern.
		 */
		word.store(fair | cast(size_t) newTail, MemoryOrder.Release);

		// Make sure our bit trickery remains valid.
		static assert((Handoff.Barging + Fairness.Fair) == Handoff.Direct);

		// Wake up the blocked thread.
		head.next = null;
		head.handoff.store(Handoff.Barging + fair, MemoryOrder.Release);
		head.waiter.wakeup();
	}
}

unittest locking {
	static runThread(void* delegate() dg) {
		static struct Delegate {
			void* ctx;
			void* function(void*) fun;
		}

		auto x = *(cast(Delegate*) &dg);

		import core.stdc.pthread;
		pthread_t tid;
		auto r = pthread_create(&tid, null, x.fun, x.ctx);
		assert(r == 0, "Failed to create thread!");

		return tid;
	}

	import d.sync.atomic;
	shared Mutex mutex;
	shared Atomic!uint state;

	void* run1() {
		assert(state.load() == 0);

		mutex.lock();
		assert(mutex.word.load() == 0x01, "Invalid mutext state!");
		state.store(1);
		mutex.unlock();

		while (state.load() != 2) {
			sched_yield();
		}

		return null;
	}

	void* run2() {
		while (state.load() != 1) {
			sched_yield();
		}

		assert(state.load() == 1);

		mutex.lock();
		assert(mutex.word.load() == 0x01, "Invalid mutext state!");
		state.store(2);
		mutex.unlock();

		return null;
	}

	auto t1 = runThread(run1);
	auto t2 = runThread(run2);

	void* ret;

	import core.stdc.pthread;
	pthread_join(t1, &ret);
	pthread_join(t2, &ret);

	assert(mutex.word.load() == 0x00, "Invalid mutext state!");

	shared Atomic!uint count;
	void* hammer() {
		foreach (i; 0 .. 1024) {
			mutex.lock();
			count.fetchAdd(1);
			if ((i >> 1) & 0x03) {
				mutex.unlock();
			} else {
				mutex.unlockFairly();
			}
		}

		return null;
	}

	pthread_t[1024] ts;
	foreach (i; 0 .. ts.length) {
		ts[i] = runThread(hammer);
	}

	foreach (i; 0 .. ts.length) {
		pthread_join(ts[i], &ret);
	}

	assert(mutex.word.load() == 0x00, "Invalid mutext state!");
	assert(count.load() == 1024 * 1024);
}

extern(C) int sleep(int);

unittest fairness {
	static runThread(void* delegate() dg) {
		static struct Delegate {
			void* ctx;
			void* function(void*) fun;
		}

		auto x = *(cast(Delegate*) &dg);

		import core.stdc.pthread;
		pthread_t tid;
		auto r = pthread_create(&tid, null, x.fun, x.ctx);
		assert(r == 0, "Failed to create thread!");

		return tid;
	}

	enum ThreadCount = 8;

	import d.sync.atomic;
	uint[ThreadCount] counts;
	shared Mutex mutex;
	shared Atomic!uint keepGoing;

	auto run(uint i) {
		void* fun() {
			auto index = i;
			while (keepGoing.load() != 0) {
				mutex.lock();
				counts[index]++;
				mutex.unlockFairly();
			}

			return null;
		}

		return runThread(fun);
	}

	// Start the threads.
	keepGoing.store(true);
	mutex.lock();

	import core.stdc.pthread;
	pthread_t[ThreadCount] ts;
	foreach (i; 0 .. ThreadCount) {
		ts[i] = run(i);
	}

	mutex.unlock();

	sleep(1);
	keepGoing.store(false);

	import core.stdc.stdio;
	printf("Fairness results:\n");

	foreach (i; 0 .. ThreadCount) {
		void* ret;
		pthread_join(ts[i], &ret);
		printf("\t%4d => %16u\n", i, counts[i]);
	}
}

unittest condition {
	static runThread(void* delegate() dg) {
		static struct Delegate {
			void* ctx;
			void* function(void*) fun;
		}

		auto x = *(cast(Delegate*) &dg);

		import core.stdc.pthread;
		pthread_t tid;
		auto r = pthread_create(&tid, null, x.fun, x.ctx);
		assert(r == 0, "Failed to create thread!");

		return tid;
	}

	enum ThreadCount = 1024;

	shared Mutex mutex;
	uint next = -1;

	auto run(uint i) {
		void* fun() {
			bool check0() {
				return next == i;
			}

			bool check1() {
				return next == i;
			}

			mutex.lock();

			mutex.waitFor(check0);
			next++;

			mutex.waitFor(check1);
			next--;

			mutex.unlock();

			return null;
		}

		return runThread(fun);
	}

	// Start the threads.
	mutex.lock();

	import core.stdc.pthread;
	pthread_t[ThreadCount] ts;
	foreach (i; 0 .. ThreadCount) {
		ts[i] = run(i);
	}

	bool reachedReversePoint() {
		return next == ThreadCount;
	}

	bool reachedStartPoint() {
		return next == -1;
	}

	// Hand things over to the threads.
	next = 0;
	mutex.waitFor(reachedReversePoint);

	next--;
	mutex.waitFor(reachedStartPoint);

	mutex.unlock();

	// Now join them all and check next.
	foreach (i; 0 .. ThreadCount) {
		void* ret;
		pthread_join(ts[i], &ret);
	}

	mutex.lock();
	assert(next == -1);
	mutex.unlock();
}
