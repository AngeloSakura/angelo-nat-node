package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/AngeloSakura/angelo-nat-node/internal/node"
)

func TestNormalizeMenuBasePath(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{input: "/", want: "/"},
		{input: "node-path", want: "/node-path/"},
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
	for _, input := range []string{"", "/panel path", "/panel\n"} {
		if _, err := normalizeMenuBasePath(input); err == nil {
			t.Fatalf("normalizeMenuBasePath(%q) accepted invalid value", input)
		}
	}
}

func TestInitConfigPersistsNormalizedBasePath(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := initConfig(configPath, ":20001", "node-path", "/usr/local/lib/angelo-node/xray", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var cfg node.Config
	if err = json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.BasePath != "/node-path/" {
		t.Fatalf("saved basePath = %q; want %q", cfg.BasePath, "/node-path/")
	}
	if cfg.Listen != ":20001" {
		t.Fatalf("saved listen = %q; want %q", cfg.Listen, ":20001")
	}
}
