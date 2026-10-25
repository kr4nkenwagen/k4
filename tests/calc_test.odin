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
	}
	for c in cases {
		got, ok := logic.calc_eval(c[0])
		testing.expectf(t, ok && got == c[1], "%q: got %q ok=%v, want %q", c[0], got, ok, c[1])
	}
	bads := []string{"", "2 +", "(1", "foo(2)", "1/0"}
	for bad in bads {
		_, ok := logic.calc_eval(bad)
		testing.expectf(t, !ok, "%q should not evaluate", bad)
	}
}
