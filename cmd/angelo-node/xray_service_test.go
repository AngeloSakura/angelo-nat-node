package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSystemdXrayState(t *testing.T) {
	standard := "LoadState=loaded\nActiveState=active\nExecStart={ path=/usr/local/bin/x-ui ; argv[]=/usr/local/bin/x-ui -config /etc/angelo-node/config.json ; ignore_errors=no ; }\n"
	for _, tc := range []struct {
		name, output string
		active, fail bool
	}{
		{"running", standard, true, false},
		{"stopped", strings.Replace(standard, "ActiveState=active", "ActiveState=inactive", 1), false, false},
		{"missing", "LoadState=not-found\nActiveState=inactive\n", false, true},
		{"wrong config", strings.ReplaceAll(standard, "/etc/angelo-node/config.json", "/etc/another.json"), false, true},
		{"empty response", "", false, true},
		{"transition", strings.Replace(standard, "ActiveState=active", "ActiveState=deactivating", 1), false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			active, err := parseSystemdXrayState(tc.output)
			if active != tc.active || (err != nil) != tc.fail {
				t.Fatalf("active=%v err=%v", active, err)
			}
		})
	}
}

func TestXraySwitchRejectsCustomInstallation(t *testing.T) {
	if err := standardXrayInstallation("/usr/local/bin/x-ui", "/etc/angelo-node/config.json"); err != nil {
		t.Fatal(err)
	}
	for _, paths := range [][2]string{{"/tmp/x-ui", "/etc/angelo-node/config.json"}, {"/usr/local/bin/x-ui", "/tmp/config.json"}} {
		if err := standardXrayInstallation(paths[0], paths[1]); err == nil {
			t.Fatal("accepted custom installation")
		}
	}
}

func TestXraySwitchStateQueryFailure(t *testing.T) {
	for _, failAt := range []int{1, 2, 3} {
		t.Run(string(rune('0'+failAt)), func(t *testing.T) {
			dir := t.TempDir()
			old, candidate := filepath.Join(dir, "xray"), filepath.Join(dir, "candidate")
			os.WriteFile(old, []byte("old"), 0755)
			os.WriteFile(candidate, []byte("new"), 0755)
			queries, starts := 0, 0
			running := true
			queryFailure := errors.New("service query failed")
			ops := xraySwitchOps{
				active: func() (bool, error) {
					queries++
					if queries == failAt {
						return false, queryFailure
					}
					return running, nil
				},
				stop:     func() error { running = false; return nil },
				start:    func() error { starts++; running = true; return nil },
				validate: func(string) error { return nil },
				healthy:  func() error { return errors.New("health failure") },
			}
			backup, err := replaceXray(candidate, old, ops)
			if err == nil || !strings.Contains(err.Error(), queryFailure.Error()) {
				t.Fatalf("missing query error: %v", err)
			}
			got, _ := os.ReadFile(old)
			if failAt < 3 && string(got) != "old" {
				t.Fatal("replaced binary after unknown service state")
			}
			if failAt == 1 && starts != 0 {
				t.Fatal("started service after initial query failure")
			}
			if failAt == 3 {
				if string(got) != "new" {
					t.Fatal("unsafe rollback after query failure")
				}
				b, _ := os.ReadFile(backup)
				if string(b) != "old" {
					t.Fatal("rollback backup lost")
				}
			}
		})
	}
}
