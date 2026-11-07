package node

import "encoding/json"

func markReset(ib *Inbound, now int64) {
	if ib.Extra == nil {
		ib.Extra = map[string]json.RawMessage{}
	}
	b, _ := json.Marshal(now)
	ib.Extra["lastTrafficResetTime"] = b
}
