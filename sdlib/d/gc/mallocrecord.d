module d.gc.mallocrecord;

private shared typeof(&malloc) mallocptr;
private shared typeof(&realloc) reallocptr;
private shared typeof(&free) freeptr;


void ensureHooks(void* req) {
	// load all the hooks
	if(req is null) {
		import core.stdc.dlfcn;
		mallocptr = cast(typeof(mallocptr)) dlsym(RTLD_NEXT, "malloc");
		reallocptr = cast(typeof(reallocptr)) dlsym(RTLD_NEXT, "realloc");
		freeptr = cast(typeof(freeptr)) dlsym(RTLD_NEXT, "free");
	}
}

extern(C) void* malloc(size_t size) {
	ensureHooks(mallocptr);
	auto ptr = mallocptr(size);
	// record a range
	mallocList.addRange(ptr[0 .. size]);
	return ptr;
}

extern(C) void free(void* ptr)
{
	ensureHooks(freeptr);
	// remove the range
	mallocList.removeRange(ptr);
	freeptr(ptr);
}

extern(C) void* realloc(void* ptr, size_t newsize)
{
	ensureHooks(reallocptr);
	if(ptr is null)
		return malloc(newsize);
	if(newsize == 0)
	{
		free(ptr);
		return null;
	}
	auto result = reallocptr(ptr, newsize);
	mallocList.updateRange(ptr, result[0 .. newsize]);
	return result;
}

extern(C) void* calloc(size_t size, size_t elemsize)
{
	ensureHooks(mallocptr);
	auto allocSize = size * elemsize;
	auto result = mallocptr(allocSize);
	memset(result, 0, allocSize);
	mallocList.addRange(result[0 .. allocSize]);
	return result;
}

struct MallocRangeBuffer {
private:
	import d.sync.mutex;
	Mutex mutex;
	const(void)[][] buffer;
	size_t len;
	const(void)[][4096] initial;
public:
	void addRange(const void[] range) shared
	{
		if(range.ptr is null)
		{
			return;
		}
		mutex.lock();
		scope(exit) mutex.unlock();
		(cast(MallocRangeBuffer*)&this).addRangeImpl(range);
	}

	void removeRange(const void* rangePtr) shared
	{
		if(rangePtr is null)
		{
			return;
		}
		mutex.lock();
		scope(exit) mutex.unlock();
		(cast(MallocRangeBuffer*)&this).removeRangeImpl(rangePtr);
	}

	void updateRange(const void* origRangePtr, void[] newRange) shared
	{
		mutex.lock();
		scope(exit) mutex.unlock();
		(cast(MallocRangeBuffer*)&this).updateRangeImpl(origRangePtr, newRange);
	}

	void[] getRangeFromPtr(const void* interior) shared
	{
		if(interior is null)
			return [];
		mutex.lock();
		scope(exit) mutex.unlock();
		return (cast(MallocRangeBuffer*)&this).getRangeFromPtrImpl(interior);
	}

	// IMPORTANT! only call from forked process
	void resetLock() shared {
		import core.stdc.stdlib;
		memset(cast(void*)&mutex, 0, Mutex.sizeof);
	}

	// IMPORTANT! only use this list with the world stopped, as it can be modified while running.
	const(void[][]) getList() shared {
		auto mrb = cast(MallocRangeBuffer*)&this;
		return mrb.buffer[0 .. mrb.len];
	}

private:
	void addRangeImpl(const(void)[] range)
	{
		if(buffer.ptr is null)
			buffer = initial.ptr[0 .. initial.length];
		if(len == buffer.length)
		{
			// grow
			import d.gc.tcache;
			auto newCap = buffer.length + 4096;
			auto newSize = newCap * (const(void)[]).sizeof;
			void* newPtr;
			if(buffer.ptr is initial.ptr) {
				// need to copy the inital buffer
				newPtr = threadCache.alloc(newSize, false, false);
				assert(newPtr !is null);
				memcpy(newPtr, buffer.ptr, buffer.length * (const(void)[]).sizeof);
			} else {
				newPtr = threadCache.realloc(buffer.ptr, newSize, false);
				assert(newPtr !is null);
			}
			buffer = (cast(const(void)[]*)newPtr)[0 .. newCap];
		}
		buffer[len++] = range;
	}

	long findRangeForPtr(const(void*) ptr, bool interior)
	{
		foreach(i; 0 .. len)
		{
			if(buffer[i].ptr is ptr)
				return i;
			if(interior && ptr > buffer[i].ptr && ptr - buffer[i].ptr < buffer[i].length)
				return i;
		}
		return -1;
	}

	void removeRangeImpl(const(void*) ptr)
	{
		auto idx = findRangeForPtr(ptr, false);
		if(idx != -1)
		{
			buffer[idx] = buffer[--len];
		}
	}

	void updateRangeImpl(const(void*) origRangePtr, const(void)[] newRange) {
		// simple algorithm, remove and then add.
		removeRangeImpl(origRangePtr);
		addRangeImpl(newRange);
	}

	void[] getRangeFromPtrImpl(const void* interior) {
		auto idx = findRangeForPtr(interior, true);
		if(idx == -1)
			return [];
		return buffer[idx];
	}
}

shared MallocRangeBuffer mallocList;
