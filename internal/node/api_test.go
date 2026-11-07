package node

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBearerControlsInboundAndSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{Token: strings.Repeat("s", 48), StateDir: dir, BasePath: "/edge/", MaxClients: 64, MaxInbounds: 16}
	app, err := Open(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	request := func(app *Node, method, path, token, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "/edge/panel/api/"+path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		out := httptest.NewRecorder()
		app.ServeHTTP(out, req)
		return out
	}
	denied := request(app, "GET", "inbounds/list", "wrong", "")
	if denied.Code != http.StatusUnauthorized {
		t.Fatalf("bad token status=%d", denied.Code)
	}
	payload := `{"enable":true,"port":12345,"protocol":"vless","tag":"in-test","settings":"{\"decryption\":\"none\",\"clients\":[{\"id\":\"f0000000-0000-4000-8000-000000000001\",\"email\":\"alice\",\"enable\":true,\"totalGB\":1000}]}","streamSettings":"{\"network\":\"tcp\"}","sniffing":"{}"}`
	added := request(app, "POST", "inbounds/add", cfg.Token, payload)
	var result struct {
		Success bool
		Obj     Inbound
		Msg     string
	}
	if err := json.Unmarshal(added.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if !result.Success || result.Obj.ID != 1 {
		t.Fatalf("create=%s", added.Body.String())
	}
	restarted, err := Open(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	listed := request(restarted, "GET", "inbounds/list", cfg.Token, "")
	var list struct {
		Success bool
		Obj     []Inbound
	}
	if err := json.Unmarshal(listed.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if !list.Success || len(list.Obj) != 1 || list.Obj[0].Tag != "in-test" {
		t.Fatalf("persistent list=%s", listed.Body.String())
	}
}
