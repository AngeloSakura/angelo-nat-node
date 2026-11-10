package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestReplaceXrayPreservationAndRollback(t *testing.T) {
	for _, mode := range []string{"success", "inactive", "invalid config", "start failure", "health failure", "stop failure"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			old := filepath.Join(dir, "xray")
			candidate := filepath.Join(dir, "candidate")
			os.WriteFile(old, []byte("old"), 0755)
			os.WriteFile(candidate, []byte("new"), 0755)
			state := filepath.Join(dir, "state.json")
			os.WriteFile(state, []byte(`{"traffic":123,"token":"unchanged"}`), 0600)
			running := mode != "inactive"
			starts := 0
			ops := xraySwitchOps{
				active: func() (bool, error) { return running, nil },
				stop: func() error {
					if mode == "stop failure" {
						return errors.New("cannot stop")
					}
					running = false
					return nil
				},
				start: func() error {
					starts++
					if mode == "start failure" && starts == 1 {
						return errors.New("cannot start")
					}
					running = true
					return nil
				},
				validate: func(path string) error {
					if running {
						t.Fatal("validate while old Xray still running")
					}
					if mode == "invalid config" {
						return errors.New("invalid config")
					}
					return nil
				},
				healthy: func() error {
					b, _ := os.ReadFile(old)
					if mode == "health failure" && string(b) == "new" {
						return errors.New("unhealthy")
					}
					return nil
				},
			}
			backup, err := replaceXray(candidate, old, ops)
			wantErr := mode != "success" && mode != "inactive"
			if (err != nil) != wantErr {
				t.Fatalf("switch: %v", err)
			}
			want := "new"
			if wantErr {
				want = "old"
			}
			got, _ := os.ReadFile(old)
			if string(got) != want {
				t.Fatalf("binary: %s", got)
			}
			b, _ := os.ReadFile(backup)
			if string(b) != "old" {
				t.Fatalf("backup: %s", b)
			}
			b, _ = os.ReadFile(state)
			if string(b) != `{"traffic":123,"token":"unchanged"}` {
				t.Fatal("state changed")
			}
			if running != (mode != "inactive") {
				t.Fatalf("service running: %v", running)
			}
		})
	}
}
