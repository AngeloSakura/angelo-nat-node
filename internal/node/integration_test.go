package node

import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func apiRequest(t *testing.T, app *Node, path string, value any) []byte {
	t.Helper()
	b, _ := json.Marshal(value)
	r := httptest.NewRequest("POST", "/panel/api/"+path, strings.NewReader(string(b)))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+app.cfg.Token)
	w := httptest.NewRecorder()
	app.ServeHTTP(w, r)
	var envelope struct {
		Success bool
		Msg     string
	}
	if err := json.Unmarshal(w.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if !envelope.Success {
		t.Fatalf("%s: %s", path, w.Body.String())
	}
	return w.Body.Bytes()
}
func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return p
}
func testInbound(port int) Object {
	return Object{"enable": true, "port": port, "listen": "127.0.0.1", "protocol": "vless", "tag": fmt.Sprintf("in-%d", port), "settings": Object{"decryption": "none", "clients": []Object{{"id": "f0000000-0000-4000-8000-000000000001", "email": "alice", "enable": true, "totalGB": 10000000}}}, "streamSettings": Object{"network": "tcp", "security": "none"}, "sniffing": Object{"enabled": false}}
}
func TestOfficialXrayTrafficQuotaAndRestart(t *testing.T) {
	binary := os.Getenv("XRAY_BINARY")
	if binary == "" {
		t.Skip("set XRAY_BINARY to an unchanged official Xray executable")
	}
	port := freePort(t)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, strings.Repeat("x", 32768)) }))
	defer upstream.Close()
	cfg := Config{Token: strings.Repeat("s", 48), StateDir: t.TempDir(), BasePath: "/", XrayPath: binary, APIAddress: fmt.Sprintf("127.0.0.1:%d", freePort(t)), PollSeconds: 2}
	// Xray 26.10 defaults to blocking private destinations. Allow only this fixture.
	cfg.DirectSettings = Object{"finalRules": []Object{{"action": "allow", "ip": []string{"127.0.0.1"}, "port": upstream.Listener.Addr().(*net.TCPAddr).Port}}}
	core, err := NewProcess(cfg)
	if err != nil {
		t.Fatal(err)
	}
	app, err := Open(cfg, core)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err = app.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	apiRequest(t, app, "inbounds/add", testInbound(port))
	if err = fetchVLESS(port, upstream.Listener.Addr().(*net.TCPAddr).Port); err != nil {
		t.Fatalf("%v; Xray log: %s; configuration: %s", err, core.log.String(), core.config)
	}
	time.Sleep(100 * time.Millisecond)
	apiRequest(t, app, "inbounds/pushClientTraffics", Object{"masterGuid": "master", "traffics": []Object{{"email": "alice", "up": 10000000, "down": 0}}})
	raw := app.state.Traffic["alice"].Down
	if raw < 32768 || raw >= 10000000 {
		t.Fatalf("raw bytes=%d: missing traffic or multiplier feedback", raw)
	}
	if err = fetchVLESS(port, upstream.Listener.Addr().(*net.TCPAddr).Port); err == nil {
		t.Fatal("quota-exhausted client still forwards traffic")
	}
	if app.state.Traffic["alice"].Down != raw {
		t.Fatal("master push modified raw counters")
	}
	apiRequest(t, app, "clients/resetTraffic/alice", nil)
	if err = fetchVLESS(port, upstream.Listener.Addr().(*net.TCPAddr).Port); err != nil {
		t.Fatalf("reset did not restore client: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	apiRequest(t, app, "server/restartXrayService", nil)
	before := app.state.Traffic["alice"].Down
	if before < 32768 {
		t.Fatalf("restart discarded traffic: %d", before)
	}
	if err = fetchVLESS(port, upstream.Listener.Addr().(*net.TCPAddr).Port); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if err = app.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := reopened.state.Traffic["alice"].Down; got <= before || got > before+40000 {
		t.Fatalf("persistent restart counter=%d previous=%d", got, before)
	}
}
func fetchVLESS(port, target int) error {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	id, _ := hex.DecodeString("f0000000000040008000000000000001")
	request := append([]byte{0}, id...)
	request = append(request, 0, 1, byte(target>>8), byte(target), 1, 127, 0, 0, 1)
	request = append(request, []byte("GET / HTTP/1.1\r\nHost: 127.0.0.1:"+strconv.Itoa(target)+"\r\nConnection: close\r\n\r\n")...)
	if _, err = conn.Write(request); err != nil {
		return err
	}
	header := make([]byte, 2)
	if _, err = io.ReadFull(conn, header); err != nil {
		return err
	}
	if header[0] != 0 {
		return fmt.Errorf("VLESS version response %d", header[0])
	}
	if header[1] > 0 {
		if _, err = io.CopyN(io.Discard, conn, int64(header[1])); err != nil {
			return err
		}
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	count, err := io.Copy(io.Discard, response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode != 200 || count != 32768 {
		return fmt.Errorf("upstream response: %d bytes %d", response.StatusCode, count)
	}
	return nil
}
