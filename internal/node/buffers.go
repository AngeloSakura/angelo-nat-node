package node

import (
	"encoding/json"
	"strconv"
)

// Configure original Xray's Linux per-socket options, never global sysctls.
// Linux doubles SO_SNDBUF/SO_RCVBUF internally; these cap autotuning rather
// than allocating the whole allowance immediately. Explicit options win.
func (n *Node) boundedSockets(original Object) Object {
	data, _ := json.Marshal(original)
	stream := Object{}
	_ = json.Unmarshal(data, &stream)
	if stream == nil {
		stream = Object{}
	}
	if n.cfg.SocketBufferKB < 0 {
		return stream
	}
	kb := n.cfg.SocketBufferKB
	if kb == 0 {
		kb = 32
	}
	raw, _ := json.Marshal(stream["sockopt"])
	sockopt := Object{}
	_ = json.Unmarshal(raw, &sockopt)
	if sockopt == nil {
		sockopt = Object{}
	}
	raw, _ = json.Marshal(sockopt["customSockopt"])
	var options []Object
	_ = json.Unmarshal(raw, &options)
	for _, opt := range []string{"7", "8"} {
		exists := false
		for _, option := range options {
			if str(option, "level") == "1" && str(option, "opt") == opt && (str(option, "system") == "" || str(option, "system") == "linux") {
				exists = true
			}
		}
		if !exists {
			options = append(options, Object{"system": "linux", "network": "tcp", "level": "1", "opt": opt, "value": strconv.Itoa(kb * 1024), "type": "int"})
		}
	}
	sockopt["customSockopt"] = options
	stream["sockopt"] = sockopt
	return stream
}
