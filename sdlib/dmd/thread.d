module dmd.thread;

alias ScanDg = void delegate(const(void*)[] range);

extern(C):

// druntime API.
void thread_suspendAll();
void thread_resumeAll();

// note, we must interface with DMD using extern(C) calls, so we
// cannot call thread_scanAll directly. This requires a hook compiled
// on the druntime side that forwards to thread_scanAll, and we cannot
// use delegates (as those are not the same ABI)
// the context pointer is just a pass-through for the druntime side, so we
// type it based on what we are passing.
void __sd_scanAllThreadsFn(ScanDg* context, void* start, void* end) {
	import d.gc.range;
	(*context)(makeRange(start, end));
}

// defined in druntime. The context pointer gets passed to the scan routine
void thread_scanAll_C(ScanDg* context, typeof(&__sd_scanAllThreadsFn) scan);

// sdrt API.
void __sd_thread_scan(ScanDg scan) {
	// we do nothing here, because this is called from each *scanner* thread.
	// All the stack/tls is added from the global scan call from druntime.
}

void __sd_global_scan(ScanDg scan) {
	import d.gc.global;
	// scan all registered roots and ranges.
	gState.scanRoots(scan);

	// this actually scans the thread stacks, registers, and TLS.
	thread_scanAll_C(&scan, &__sd_scanAllThreadsFn);
}

void __sd_thread_stop_the_world() {
	// this stops all other threads, and registers the stacks to be scanned.
	thread_suspendAll();
}

void __sd_thread_restart_the_world() {
	thread_resumeAll();
}

void __sd_thread_create() {
	import d.gc.capi;
	__sd_gc_init();
}

void __sd_thread_destroy() {
	import d.gc.capi;
	__sd_gc_destroy_thread();
}
