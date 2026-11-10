package main

import "testing"

func TestNormalizeMenuBasePath(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{input: "/", want: "/"},
		{input: "/panel", want: "/panel/"},
		{input: "/panel/", want: "/panel/"},
		{input: "/api/v1", want: "/api/v1/"},
	}
	for _, test := range tests {
		got, err := normalizeMenuBasePath(test.input)
		if err != nil || got != test.want {
			t.Fatalf("normalizeMenuBasePath(%q) = %q, %v; want %q", test.input, got, err, test.want)
		}
	}
}

func TestNormalizeMenuBasePathRejectsInvalidValue(t *testing.T) {
	for _, input := range []string{"", "panel", "/panel path", "/panel\n"} {
		if _, err := normalizeMenuBasePath(input); err == nil {
			t.Fatalf("normalizeMenuBasePath(%q) accepted invalid value", input)
		}
	}
}
