package node

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// lifecycleRuntime models Xray process replacement separately from node traffic.
// A failed Apply may have restarted the old configuration with fresh counters.
type lifecycleRuntime struct {
	mu        sync.Mutex
	counters  map[string]int64
	applyHook func(context.Context) error
}

func (r *lifecycleRuntime) Apply(ctx context.Context, _ []byte) error {
	r.mu.Lock()
	hook := r.applyHook
	r.mu.Unlock()
	if hook != nil {
		return hook(ctx)
	}
	return nil
}
func (r *lifecycleRuntime) Stats(context.Context) (map[string]int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]int64, len(r.counters))
	for name, value := range r.counters {
		out[name] = value
	}
	return out, nil
}
func (*lifecycleRuntime) Running() bool   { return true }
func (*lifecycleRuntime) Version() string { return "test-runtime" }
func (*lifecycleRuntime) Stop() error     { return nil }
func (r *lifecycleRuntime) setHook(hook func(context.Context) error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.applyHook = hook
}
func (r *lifecycleRuntime) setUsage(value int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.counters = map[string]int64{
		"user>>>alice>>>traffic>>>uplink":           value,
		"inbound>>>in-lifecycle>>>traffic>>>uplink": value,
	}
}

const lifecycleInbound = `{"enable":true,"port":12345,"protocol":"vless","tag":"in-lifecycle","remark":"committed","settings":{"decryption":"none","clients":[{"id":"f0000000-0000-4000-8000-000000000001","email":"alice","enable":true,"totalGB":0}]},"streamSettings":{"network":"tcp"},"sniffing":{}}`

func lifecycleRequest(app *Node, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, "/panel/api/"+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+app.cfg.Token)
	if strings.HasPrefix(body, "{") {
		req.Header.Set("Content-Type", "application/json")
	} else {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	out := httptest.NewRecorder()
	app.ServeHTTP(out, req)
	return out
}
func lifecycleSuccess(t *testing.T, response *httptest.ResponseRecorder, want bool) {
	t.Helper()
	var result struct {
		Success bool `json:"success"`
	}
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d, body=%s", response.Code, response.Body.String())
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Success != want {
		t.Fatalf("success=%v, want %v: %s", result.Success, want, response.Body.String())
	}
}
func lifecycleNode(t *testing.T) (*Node, *lifecycleRuntime) {
	t.Helper()
	core := &lifecycleRuntime{}
	app, err := Open(Config{Token: strings.Repeat("s", 48), StateDir: t.TempDir(), BasePath: "/"}, core)
	if err != nil {
		t.Fatal(err)
	}
	if err := app.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	lifecycleSuccess(t, lifecycleRequest(app, http.MethodPost, "inbounds/add", lifecycleInbound), true)
	return app, core
}

func TestLifecycleReadsRemainResponsiveDuringApply(t *testing.T) {
	for _, failApply := range []bool{false, true} {
		name := "commit"
		if failApply {
			name = "rollback"
		}
		t.Run(name, func(t *testing.T) {
			app, core := lifecycleNode(t)
			entered := make(chan struct{})
			release := make(chan struct{})
			var releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(release) }) }
			defer unblock()
			core.setHook(func(ctx context.Context) error {
				close(entered)
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-release:
				}
				if failApply {
					return errors.New("injected replacement failure")
				}
				return nil
			})
			updated := strings.ReplaceAll(lifecycleInbound, "12345", "12346")
			updated = strings.ReplaceAll(updated, "committed", "pending")
			writeDone := make(chan *httptest.ResponseRecorder, 1)
			go func() { writeDone <- lifecycleRequest(app, http.MethodPost, "inbounds/update/1", updated) }()
			select {
			case <-entered:
			case <-time.After(2 * time.Second):
				t.Fatal("update never reached Runtime.Apply")
			}
			type readResult struct {
				route    string
				response *httptest.ResponseRecorder
			}
			reads := make(chan readResult, 2)
			for _, route := range []string{"server/status", "inbounds/list"} {
				go func(route string) { reads <- readResult{route, lifecycleRequest(app, http.MethodGet, route, "")} }(route)
			}
			deadline := time.NewTimer(750 * time.Millisecond)
			defer deadline.Stop()
			for i := 0; i < 2; i++ {
				select {
				case read := <-reads:
					lifecycleSuccess(t, read.response, true)
					if read.route == "inbounds/list" {
						var list struct {
							Obj []Inbound `json:"obj"`
						}
						if err := json.Unmarshal(read.response.Body.Bytes(), &list); err != nil {
							t.Fatal(err)
						}
						if len(list.Obj) != 1 || list.Obj[0].Port != 12345 || list.Obj[0].Remark != "committed" {
							t.Fatalf("read exposed an uncommitted update: %s", read.response.Body.String())
						}
					}
				case <-deadline.C:
					unblock()
					<-writeDone
					t.Fatal("GET status/list waited for Runtime.Apply instead of returning a committed snapshot")
				}
			}
			unblock()
			select {
			case response := <-writeDone:
				lifecycleSuccess(t, response, !failApply)
			case <-time.After(2 * time.Second):
				t.Fatal("update did not finish after Runtime.Apply was released")
			}
		})
	}
}

func TestLifecycleFailedApplyInvalidatesTrafficBaseline(t *testing.T) {
	for _, operation := range []string{"restart", "update", "reconcile"} {
		t.Run(operation, func(t *testing.T) {
			app, core := lifecycleNode(t)
			core.setUsage(1000)
			lifecycleSuccess(t, lifecycleRequest(app, http.MethodPost, "inbounds/1/subSortIndex", "subSortIndex=1"), true)
			core.setHook(func(context.Context) error {
				core.setUsage(0)
				return errors.New("new configuration failed; old configuration restarted")
			})
			switch operation {
			case "restart":
				lifecycleSuccess(t, lifecycleRequest(app, http.MethodPost, "server/restartXrayService", ""), false)
			case "update":
				body := strings.ReplaceAll(lifecycleInbound, "12345", "12346")
				lifecycleSuccess(t, lifecycleRequest(app, http.MethodPost, "inbounds/update/1", body), false)
			case "reconcile":
				app.mu.Lock()
				app.state.Inbounds[0].ExpiryTime = time.Now().Add(-time.Second).UnixMilli()
				err := app.reconcile(context.Background())
				app.mu.Unlock()
				if err == nil {
					t.Fatal("expected reconciliation to report replacement failure")
				}
			}
			core.setHook(nil)
			// A new process can surpass the previous process's count before the next poll.
			// A retained 1000-byte baseline would silently lose those first 1000 bytes.
			core.setUsage(1500)
			app.mu.Lock()
			err := app.collect()
			if err == nil {
				err = app.collect()
			} // A repeated sample must not double count.
			userUp := app.state.Traffic["alice"].Up
			inboundUp := app.state.Inbounds[0].Up
			app.mu.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			if userUp != 2500 || inboundUp != 2500 {
				t.Fatalf("after failed %s and runtime replacement, user=%d inbound=%d; want 2500 each", operation, userUp, inboundUp)
			}
		})
	}
}

func TestLifecycleReconcileSuppliesApplyDeadline(t *testing.T) {
	app, core := lifecycleNode(t)
	sawDeadline := false
	core.setHook(func(ctx context.Context) error {
		deadline, ok := ctx.Deadline()
		sawDeadline = ok && time.Until(deadline) > 0 && time.Until(deadline) <= 15*time.Second
		return errors.New("injected failure avoids waiting for the deadline")
	})
	app.mu.Lock()
	app.state.Inbounds[0].ExpiryTime = time.Now().Add(-time.Second).UnixMilli()
	err := app.reconcile(context.Background())
	app.mu.Unlock()
	if err == nil {
		t.Fatal("expected injected replacement failure")
	}
	if !sawDeadline {
		t.Fatal("background reconciliation supplied no bounded Apply deadline (expected at most 15 seconds)")
	}
}
