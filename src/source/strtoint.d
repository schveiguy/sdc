module source.strtoint;

ulong strToInt(string s) {
	if (s.length < 3 || s[0] != '0') {
		goto ParseDec;
	}

	switch (s[1]) {
		case 'x', 'X':
			return strToHexInt(s[2 .. $]);

		case 'b', 'B':
			return strToBinInt(s[2 .. $]);

		default:
			// Break to parse as decimal.
			break;
	}

ParseDec:
	return strToDecInt(s);
}

unittest {
	assert(strToInt("") == 0);
	assert(strToInt("0") == 0);
	assert(strToInt("42") == 42);
	assert(strToInt("123") == 123);
	assert(strToInt("0x0") == 0);
	assert(strToInt("0xaa") == 170);
	assert(strToInt("0b101") == 5);
}

ulong strToDecInt(string s) {
	ulong result = 0;

	foreach (i; 0 .. s.length) {
		if (s[i] == '_') {
			continue;
		}

		auto d = s[i] - '0';

		assert(d < 10, "Only digits are expected here.");
		result = 10 * result + d;
	}

	return result;
}

unittest {
	assert(strToDecInt("") == 0);
	assert(strToDecInt("0") == 0);
	assert(strToDecInt("42") == 42);
	assert(strToDecInt("1234567890") == 1234567890);
	assert(strToDecInt("18446744073709551615") == 18446744073709551615UL);
	assert(strToDecInt("34_56") == 3456);
}

ulong strToBinInt(string s) {
	ulong result = 0;

Start:
	import source.swar.bin;
	while (startsWithBinDigits!8(s)) {
		result <<= 8;
		result |= parseBinDigits!ubyte(s);
		s = s[8 .. $];
	}

	foreach (i; 0 .. s.length) {
		auto c = s[i];
		if (c == '_') {
			s = s[i + 1 .. $];
			goto Start;
		}

		assert(c == '0' || c == '1', "Only 0 and 1 are accepted here.");
		result = (result << 1) | (c & 0x01);
	}

	return result;
}

unittest {
	assert(strToBinInt("") == 0);
	assert(strToBinInt("0") == 0);
	assert(strToBinInt("1010") == 10);
	assert(strToBinInt("0101010") == 42);
	assert(strToBinInt(
		"0101010101010101010101010101010101010101010101010101010101010101",
	) == 0x5555555555555555);
	assert(strToBinInt(
		"0110011001100110011001100110011001100110011001100110011001100110",
	) == 0x6666666666666666);
	assert(strToBinInt(
		"1001100110011001100110011001100110011001100110011001100110011001",
	) == 0x9999999999999999);
	assert(strToBinInt(
		"1010101010101010101010101010101010101010101010101010101010101010",
	) == 0xaaaaaaaaaaaaaaaa);
	assert(strToBinInt(
		"1111111111111111111111111111111111111111111111111111111111111111",
	) == 0xffffffffffffffff);
	assert(strToBinInt("11_101_00") == 116);
}

ulong strToHexInt(string s) {
	ulong result = 0;

Start:
	import source.swar.hex;
	while (startsWithHexDigits!8(s)) {
		result <<= 32;
		result |= parseHexDigits!uint(s);
		s = s[8 .. $];
	}

	foreach (i; 0 .. s.length) {
		auto c = s[i];
		if (c == '_') {
			s = s[i + 1 .. $];
			goto Start;
		}

		import std.ascii;
		assert(isHexDigit(c), "Only hex digits are accepted here.");

		auto n = (c & 0x0f) + 9 * (c >> 6);
		result = (result << 4) | n;
	}

	return result;
}

unittest {
	assert(strToHexInt("") == 0);
	assert(strToHexInt("0") == 0);
	assert(strToHexInt("A") == 10);
	assert(strToHexInt("a") == 10);
	assert(strToHexInt("F") == 15);
	assert(strToHexInt("f") == 15);
	assert(strToHexInt("42") == 66);
	assert(strToHexInt("AbCdEf0") == 180150000);
	assert(strToHexInt("12345aBcDeF") == 1251004370415);
	assert(strToHexInt("FFFFFFFFFFFFFFFF") == 18446744073709551615);
	assert(strToHexInt("a_B_c") == 2748);
}
