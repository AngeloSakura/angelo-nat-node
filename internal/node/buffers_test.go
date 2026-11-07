package node

import (
	"encoding/json"
	"testing"
)

func TestSocketBoundsPreserveExplicitConfig(t *testing.T) {
	n := &Node{cfg: Config{SocketBufferKB: 32}}
	original := Object{"network": "tcp", "security": "reality", "sockopt": Object{"tcpFastOpen": true, "customSockopt": []Object{{"system": "linux", "network": "tcp", "level": "1", "opt": "7", "value": "65536", "type": "int"}}}}
	before, _ := json.Marshal(original)
	actual := n.boundedSockets(original)
	after, _ := json.Marshal(original)
	if string(before) != string(after) {
		t.Fatal("modified saved/master transport")
	}
	sockopt := actual["sockopt"].(Object)
	options := sockopt["customSockopt"].([]Object)
	if len(options) != 2 || str(options[0], "value") != "65536" || str(options[1], "opt") != "8" || str(options[1], "value") != "32768" {
		t.Fatalf("unexpected socket options: %+v", options)
	}
	if actual["security"] != "reality" || sockopt["tcpFastOpen"] != true {
		t.Fatal("unrelated transport modified")
	}
	n.cfg.SocketBufferKB = -1
	disabled, _ := json.Marshal(n.boundedSockets(original))
	if string(disabled) != string(before) {
		t.Fatal("disable flag changed configuration")
	}
}
