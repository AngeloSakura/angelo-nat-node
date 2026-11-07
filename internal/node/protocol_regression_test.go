package node

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// protocolRuntime models per-process counters: applying a configuration restarts
// Xray and clears those counters, while the node must retain cumulative usage.
type protocolRuntime struct {
	counters map[string]int64
	config   []byte
	running  bool
}

func (p *protocolRuntime) Apply(_ context.Context, config []byte) error {
	p.config = bytes.Clone(config)
	p.counters = map[string]int64{}
	p.running = true
	return nil
}
func (p *protocolRuntime) Stats(context.Context) (map[string]int64, error) {
	result := map[string]int64{}
	for name, value := range p.counters {
		result[name] = value
	}
	return result, nil
}
func (p *protocolRuntime) Running() bool   { return p.running }
func (p *protocolRuntime) Version() string { return "protocol-test" }
func (p *protocolRuntime) Stop() error     { p.running = false; return nil }
func (p *protocolRuntime) traffic(email string, up, down int64) {
	p.counters["user>>>"+email+">>>traffic>>>uplink"] += up
	p.counters["user>>>"+email+">>>traffic>>>downlink"] += down
}

func protocolNode(t *testing.T) (*Node, *protocolRuntime, Config) {
	t.Helper()
	cfg := Config{Token: strings.Repeat("r", 48), StateDir: t.TempDir(), BasePath: "/", APIAddress: "127.0.0.1:10085", MaxClients: 64, MaxInbounds: 16}
	core := &protocolRuntime{}
	app, err := Open(cfg, core)
	if err != nil {
		t.Fatal(err)
	}
	if err := app.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	return app, core, cfg
}

func protocolRequest(t *testing.T, app *Node, method, path string, payload any, obj any) {
	t.Helper()
	var body []byte
	if payload != nil {
		var err error
		body, err = json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, "/panel/api/"+path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+app.cfg.Token)
	req.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	app.ServeHTTP(response, req)
	var envelope struct {
		Success bool
		Msg     string
		Obj     json.RawMessage
	}
	if response.Code != http.StatusOK {
		t.Fatalf("%s %s: HTTP %d: %s", method, path, response.Code, response.Body.String())
	}
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if !envelope.Success {
		t.Fatalf("%s %s: %s", method, path, envelope.Msg)
	}
	if obj != nil {
		if err := json.Unmarshal(envelope.Obj, obj); err != nil {
			t.Fatal(err)
		}
	}
}

func protocolClient(email string) Object {
	return Object{"id": "f0000000-0000-4000-8000-000000000001", "email": email, "enable": true, "totalGB": int64(10000), "expiryTime": int64(0)}
}
func protocolAddInbound(t *testing.T, app *Node, port int, clients ...Object) Inbound {
	t.Helper()
	var result Inbound
	protocolRequest(t, app, "POST", "inbounds/add", Object{"enable": true, "port": port, "listen": "127.0.0.1", "protocol": "vless", "tag": fmt.Sprintf("in-%d", port), "settings": Object{"decryption": "none", "clients": clients}, "streamSettings": Object{"network": "tcp", "security": "none"}}, &result)
	return result
}
func protocolList(t *testing.T, app *Node) []Inbound {
	t.Helper()
	var result []Inbound
	protocolRequest(t, app, "GET", "inbounds/list", nil, &result)
	return result
}
func protocolDiskState(t *testing.T, cfg Config) State {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(cfg.StateDir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	var state State
	if err := json.Unmarshal(b, &state); err != nil {
		t.Fatal(err)
	}
	return state
}
func protocolPush(t *testing.T, app *Node, rows ...Traffic) {
	t.Helper()
	protocolRequest(t, app, "POST", "inbounds/pushClientTraffics", Object{"masterGuid": "master", "traffics": rows}, nil)
}

func TestProtocolDetachLastAttachmentRetainsTrafficOnReattach(t *testing.T) {
	app, core, cfg := protocolNode(t)
	defer app.Close()
	client := protocolClient("alice")
	ib := protocolAddInbound(t, app, 11001, client)
	core.traffic("alice", 17, 29)
	protocolPush(t, app, Traffic{Email: "alice", Up: 51, Down: 87})
	protocolRequest(t, app, "POST", "clients/alice/detach", Object{"inboundIds": []int{ib.ID}}, nil)
	state := protocolDiskState(t, cfg)
	if got := state.Traffic["alice"]; got == nil || got.Up != 17 || got.Down != 29 {
		t.Fatalf("last detach lost cumulative usage: %+v", got)
	}
	if got := state.Global["master"]["alice"]; got.Up != 51 || got.Down != 87 {
		t.Fatalf("last detach lost master overlay: %+v", got)
	}
	protocolRequest(t, app, "POST", "clients/add", Object{"client": client, "inboundIds": []int{ib.ID}}, nil)
	listed := protocolList(t, app)
	if len(listed) != 1 || len(listed[0].ClientStats) != 1 {
		t.Fatalf("reattachment missing client: %+v", listed)
	}
	if got := listed[0].ClientStats[0]; got.Up != 17 || got.Down != 29 {
		t.Fatalf("reattachment reset/doubled raw usage: %+v", got)
	}
}

func TestProtocolPartialGlobalPushPreservesOmittedClients(t *testing.T) {
	app, core, cfg := protocolNode(t)
	defer app.Close()
	protocolAddInbound(t, app, 11002, protocolClient("alice"), protocolClient("bob"))
	core.traffic("alice", 11, 13)
	core.traffic("bob", 17, 19)
	protocolPush(t, app, Traffic{Email: "alice", Up: 30, Down: 40}, Traffic{Email: "bob", Up: 50, Down: 60})
	protocolPush(t, app, Traffic{Email: "alice", Up: 3, Down: 4})
	protocolPush(t, app)
	state := protocolDiskState(t, cfg)
	if got := state.Global["master"]["bob"]; got.Up != 50 || got.Down != 60 {
		t.Errorf("partial/empty push removed omitted client: %+v", got)
	}
	if got := state.Global["master"]["alice"]; got.Up != 3 || got.Down != 4 {
		t.Errorf("lower authoritative push was not retained: %+v", got)
	}
	for email, want := range map[string][2]int64{"alice": {11, 13}, "bob": {17, 19}} {
		if got := state.Traffic[email]; got == nil || got.Up != want[0] || got.Down != want[1] {
			t.Errorf("global push changed raw usage for %s: %+v", email, got)
		}
	}
}

func TestProtocolDelayedExpiryActivatesOnceForSharedClient(t *testing.T) {
	app, core, cfg := protocolNode(t)
	defer app.Close()
	client := protocolClient("alice")
	const duration = int64(60000)
	client["expiryTime"] = -duration
	protocolAddInbound(t, app, 11003, client)
	protocolAddInbound(t, app, 11004, client)
	for _, ib := range protocolList(t, app) {
		if got := num(ib.clients()[0], "expiryTime"); got != -duration {
			t.Fatalf("expiry activated before first traffic: %d", got)
		}
	}
	before := time.Now().UnixMilli()
	core.traffic("alice", 1, 2)
	protocolPush(t, app, Traffic{Email: "alice", Up: 3, Down: 6})
	after := time.Now().UnixMilli()
	var deadline int64
	for _, ib := range protocolList(t, app) {
		got := num(ib.clients()[0], "expiryTime")
		if got < before+duration || got > after+duration {
			t.Fatalf("first use did not activate expiry: got %d, want [%d,%d]", got, before+duration, after+duration)
		}
		if deadline != 0 && deadline != got {
			t.Fatalf("shared attachments have different deadlines: %d and %d", deadline, got)
		}
		deadline = got
	}
	core.traffic("alice", 2, 3)
	protocolPush(t, app, Traffic{Email: "alice", Up: 9, Down: 15})
	if got := protocolDiskState(t, cfg).Traffic["alice"].ExpiryTime; got != deadline {
		t.Fatalf("subsequent usage changed/persisted wrong deadline: got %d want %d", got, deadline)
	}
}

func TestProtocolQuotaDisablePersistsUntilExplicitReset(t *testing.T) {
	app, core, cfg := protocolNode(t)
	client := protocolClient("alice")
	client["totalGB"] = int64(100)
	protocolAddInbound(t, app, 11005, client)
	core.traffic("alice", 10, 20)
	protocolPush(t, app, Traffic{Email: "alice", Up: 40, Down: 60})
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	core = &protocolRuntime{}
	reopened, err := Open(cfg, core)
	if err != nil {
		t.Fatal(err)
	}
	if err := reopened.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	protocolPush(t, reopened, Traffic{Email: "alice", Up: 0, Down: 0})
	listed := protocolList(t, reopened)
	if len(listed) != 1 || len(listed[0].ClientStats) != 1 {
		t.Fatalf("disabled client metadata missing: %+v", listed)
	}
	if enabled(listed[0].clients()[0]) || listed[0].ClientStats[0].Enable {
		t.Fatal("lower global push/restart re-enabled quota-disabled client")
	}
	if got := listed[0].ClientStats[0]; got.Up != 10 || got.Down != 20 {
		t.Fatalf("quota disable/restart changed raw usage: %+v", got)
	}
	protocolRequest(t, reopened, "POST", "clients/resetTraffic/alice", nil, nil)
	listed = protocolList(t, reopened)
	if !enabled(listed[0].clients()[0]) || !listed[0].ClientStats[0].Enable {
		t.Fatal("explicit reset did not re-enable client")
	}
	if got := listed[0].ClientStats[0]; got.Up != 0 || got.Down != 0 {
		t.Fatalf("explicit reset retained client raw usage: %+v", got)
	}
}

func TestProtocolSharedRenameMovesIdentityAndCountersOnce(t *testing.T) {
	app, core, cfg := protocolNode(t)
	defer app.Close()
	first := protocolAddInbound(t, app, 11006, protocolClient("alice"))
	protocolAddInbound(t, app, 11007, protocolClient("alice"))
	core.traffic("alice", 23, 31)
	protocolPush(t, app, Traffic{Email: "alice", Up: 69, Down: 93})
	protocolRequest(t, app, "POST", fmt.Sprintf("clients/update/alice?inboundIds=%d", first.ID), protocolClient("renamed"), nil)
	for _, ib := range protocolList(t, app) {
		clients := ib.clients()
		if len(clients) != 1 || str(clients[0], "email") != "renamed" {
			t.Fatalf("rename split shared identity in inbound %d: %+v", ib.ID, clients)
		}
		if len(ib.ClientStats) != 1 || ib.ClientStats[0].Up != 23 || ib.ClientStats[0].Down != 31 {
			t.Fatalf("rename reset or doubled shared usage: %+v", ib.ClientStats)
		}
	}
	state := protocolDiskState(t, cfg)
	if len(state.Traffic) != 1 || state.Traffic["alice"] != nil || state.Traffic["renamed"] == nil {
		t.Fatalf("rename retained duplicate raw identities: %+v", state.Traffic)
	}
	rows := state.Global["master"]
	if len(rows) != 1 || rows["renamed"].Up != 69 || rows["renamed"].Down != 93 {
		t.Fatalf("rename did not move authoritative overlay once: %+v", rows)
	}
}

func TestProtocolDisableFlowSuppressesRuntimeVision(t *testing.T) {
	app, core, _ := protocolNode(t)
	defer app.Close()
	client := protocolClient("alice")
	client["flow"] = "xtls-rprx-vision"
	var added Inbound
	protocolRequest(t, app, "POST", "inbounds/add", Object{"enable": true, "port": 11008, "protocol": "vless", "tag": "in-flow", "disableFlow": true, "settings": Object{"decryption": "none", "clients": []Object{client}}, "streamSettings": Object{"network": "tcp", "security": "tls"}}, &added)
	var rendered struct {
		Inbounds []Inbound `json:"inbounds"`
	}
	if err := json.Unmarshal(core.config, &rendered); err != nil {
		t.Fatal(err)
	}
	for _, ib := range rendered.Inbounds {
		if ib.Tag != "in-flow" {
			continue
		}
		clients := ib.clients()
		if len(clients) != 1 {
			t.Fatalf("runtime client missing: %+v", clients)
		}
		if got := str(clients[0], "flow"); got != "" {
			t.Fatalf("disableFlow still renders client flow %q", got)
		}
		return
	}
	t.Fatal("rendered inbound missing")
}
