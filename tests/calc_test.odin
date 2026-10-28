package tests

import "core:testing"
import "../src/logic"

@(test)
calc_matches_the_design :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"sqrt(2) * 15", "21.21320344"},
		{"1920 / 1080", "1.777777778"},
		{"2^16", "65536"},
		{"0x1F", "31"},
		{"-3 + 4*2", "5"},
		{"(1+2)*3", "9"},
		{"10 % 4", "2"},
		{"2 × 3 − 1", "5"},
		{"round(pi*100)", "314"},
		{"1e3 + 1", "1001"},
		{"15% of 2400", "360"},
		{"2400 + 15%", "2760"},
		{"2400 - 25%", "1800"},
		{"50%", "0.5"},
		{"(100 + 20) * 10%", "12"},
		{"5 km in mi", "3.106855961 mi"},
		{"30 c to f", "86 f"},
		{"2 GiB in MB", "2147.483648 MB"},
		{"90 min in h", "1.5 h"},
		{"6ft in cm", "182.88 cm"},
		{"1 kg to lb", "2.204622622 lb"},
	}
	for c in cases {
		got, ok := logic.calc_eval(c[0])
		testing.expectf(t, ok && got == c[1], "%q: got %q ok=%v, want %q", c[0], got, ok, c[1])
	}
	bads := []string{"", "2 +", "(1", "foo(2)", "1/0", "5 km in kg", "5 parsecs in m"}
	for bad in bads {
		_, ok := logic.calc_eval(bad)
		testing.expectf(t, !ok, "%q should not evaluate", bad)
	}
}
