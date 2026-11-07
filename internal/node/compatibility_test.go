package node

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
)

func TestReviewSavedClientLimitMustNotMakeStateUnopenable(t *testing.T) {
	_, _, cfg := protocolNode(t)
	cfg.MaxClients = 1
	app, err := Open(cfg, &protocolRuntime{})
	if err != nil {
		t.Fatal(err)
	}
	if err := app.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	ib := protocolAddInbound(t, app, 12001, protocolClient("alice"))
	protocolRequest(t, app, "POST", "clients/alice/detach", Object{"inboundIds": []int{ib.ID}}, nil)
	body, _ := json.Marshal(Object{"client": protocolClient("bob"), "inboundIds": []int{ib.ID}})
	response := lifecycleRequest(app, "POST", "clients/add", string(body))
	var env struct{ Success bool }
	if err := json.Unmarshal(response.Body.Bytes(), &env); err != nil {
		t.Fatal(err)
	}
	_, reopenErr := Open(cfg, nil)
	if env.Success || reopenErr != nil {
		t.Fatalf("capacity overflow accepted=%v; saved users=%d; subsequent restart error=%v", env.Success, len(protocolDiskState(t, cfg).Traffic), reopenErr)
	}
}

func TestReviewSharedRenameAcceptsPerInboundMasterSequence(t *testing.T) {
	app, _, _ := protocolNode(t)
	defer app.Close()
	vision := protocolClient("alice")
	vision["flow"] = "xtls-rprx-vision"
	first := protocolAddInbound(t, app, 12002, vision)
	second := protocolAddInbound(t, app, 12003, protocolClient("alice"))
	renamedVision := protocolClient("renamed")
	renamedVision["flow"] = "xtls-rprx-vision"
	protocolRequest(t, app, "POST", fmt.Sprintf("clients/update/alice?inboundIds=%d", first.ID), renamedVision, nil)
	for _, ib := range protocolList(t, app) {
		if ib.ID == second.ID && str(ib.clients()[0], "flow") != "" {
			t.Errorf("first scoped rename overwrote unrelated attachment flow: %+v", ib.clients()[0])
		}
	}
	body, _ := json.Marshal(protocolClient("renamed"))
	response := lifecycleRequest(app, "POST", fmt.Sprintf("clients/update/alice?inboundIds=%d", second.ID), string(body))
	var env struct {
		Success bool
		Msg     string
	}
	if err := json.Unmarshal(response.Body.Bytes(), &env); err != nil {
		t.Fatal(err)
	}
	if !env.Success {
		t.Fatalf("second master per-inbound rename failed: %s", env.Msg)
	}
}

func TestReviewLargeBilledCountersCannotBypassQuota(t *testing.T) {
	app, _, _ := protocolNode(t)
	defer app.Close()
	client := protocolClient("alice")
	client["totalGB"] = int64(100)
	protocolAddInbound(t, app, 12004, client)
	protocolPush(t, app, Traffic{Email: "alice", Up: 9000000000000000000, Down: 9000000000000000000})
	listed := protocolList(t, app)
	if len(listed) != 1 || len(listed[0].ClientStats) != 1 {
		t.Fatal("missing client")
	}
	if listed[0].ClientStats[0].Enable {
		t.Fatal("two accepted large billed counters overflowed their sum and bypassed a 100-byte quota")
	}
}
func TestOverlayReviewMalformedClientsCannotEraseRunningUsers(t *testing.T) {
	app, _, _ := protocolNode(t)
	defer app.Close()
	ib := protocolAddInbound(t, app, 12005, protocolClient("alice"))
	body, _ := json.Marshal(Object{"enable": true, "port": 12005, "protocol": "vless", "tag": ib.Tag, "settings": Object{"decryption": "none", "clients": "not-an-array"}})
	response := lifecycleRequest(app, "POST", fmt.Sprintf("inbounds/update/%d", ib.ID), string(body))
	var env struct{ Success bool }
	if err := json.Unmarshal(response.Body.Bytes(), &env); err != nil {
		t.Fatal(err)
	}
	if env.Success {
		t.Fatal("malformed clients accepted and running users silently removed")
	}
	listed := protocolList(t, app)
	if len(listed[0].clients()) != 1 {
		t.Fatal("failed mutation changed existing clients")
	}
}
