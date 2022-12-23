module source.swar.util;

auto readRaw(T)(string s) in(s.length >= T.sizeof) {
	return *(cast(T*) s.ptr);
}

auto read(T)(string s) {
	if (s.length >= T.sizeof) {
		return readRaw!T(s);
	}

	T v;
	foreach (i; 0 .. s.length) {
		v |= T(s[i]) << (8 * i);
	}

	return v;
}

auto readRaw(T)(const(ubyte)[] data) in(data.length >= T.sizeof) {
	return *(cast(T*) data.ptr);
}

auto read(T)(const(ubyte)[] data) {
	if (data.length >= T.sizeof) {
		return readRaw!T(data);
	}

	T v;
	foreach (i; 0 .. data.length) {
		v |= T(data[i]) << (8 * i);
	}

	return v;
}
