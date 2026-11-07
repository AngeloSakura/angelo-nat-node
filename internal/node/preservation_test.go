package node

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckNeverInitializesOrChangesState(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "missing")
	cfg := Config{Token: strings.Repeat("t", 32), StateDir: directory, APIAddress: "127.0.0.1:10085"}
	if Check(cfg) == nil {
		t.Fatal("missing state accepted")
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("check created directory")
	}
	app, err := Open(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "state.json")
	before, _ := os.ReadFile(path)
	if err = Check(cfg); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("check modified state")
	}
	_ = app.Close()
}

func TestHealthRejectsCoreExitDespiteCachedRunningStatus(t *testing.T) {
	app, core, _ := protocolNode(t)
	defer app.Close()
	core.running = false
	response := lifecycleRequest(app, "GET", "server/health", "")
	var result struct{ Success bool }
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Success {
		t.Fatal("cached running status concealed exited core")
	}
}
