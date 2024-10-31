module d.gc.stack;

import d.gc.types;

void printStackTopDiff(const(void*) drt, const(void*) sdc) {
	import core.stdc.stdio;
	import d.gc.collector;
	char[128] buf;
	auto len = snprintf(buf.ptr, buf.length, "stack top cmp: %p - %p = %lld",
	                    drt, sdc, drt - sdc);
	stderrSafeMessage(buf.ptr[0 .. len]);
}

version(OSX) {
	// For some reason OSX's symbol get a _ prepended.
	extern(C) void _sd_gc_push_registers(void delegate());
	alias __sd_gc_push_registers = _sd_gc_push_registers;
} else {
	extern(C) void __sd_gc_push_registers(void delegate());
}

//extern(C) void* thread_stackTop();

//extern(C) void __ext_callWithStackShell(void function(ThreadScanner* ts) fn, ThreadScanner* ths);

void scanStack(ScanDg scan) {
	auto ts = ThreadScanner(scan);
	__sd_gc_push_registers(ts.scanStack);
	//__ext_callWithStackShell(cast(void function(ThreadScanner*)) druntime_scan, &ts);
}

extern(C) void druntime_scan(ThreadScanner* ts) {
	ts.scanStack();
}

private:

struct ThreadScanner {
	ScanDg scan;

	this(ScanDg scan) {
		this.scan = scan;
	}

	void scanStack() {
		import sdc.intrinsics;
		auto top = readFramePointer();

		//auto druntimetop = thread_stackTop();
		//printStackTopDiff(druntimetop, top);
		//top = druntimetop;

		import d.gc.tcache;
		auto bottom = threadCache.stackBottom;

		import d.gc.range;
		scan(makeRange(top, bottom));
	}
}
