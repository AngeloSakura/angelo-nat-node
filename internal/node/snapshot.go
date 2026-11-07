package node

import (
	"encoding/json"
	"strconv"
)

func (n *Node) refreshViews() {
	views := map[string][]byte{}
	cache := func(method, path string, obj any, err error) {
		msg := ""
		if err != nil {
			msg = err.Error()
		}
		b, _ := json.Marshal(Object{"success": err == nil, "msg": msg, "obj": obj})
		views[method+" "+path] = b
	}
	for _, path := range []string{"server/status", "inbounds/list", "server/descendants", "hosts/list", "server/clientIps", "server/getWebCertFiles"} {
		obj, err := n.get(path)
		cache("GET", path, obj, err)
	}
	for _, ib := range n.state.Inbounds {
		cache("GET", "inbounds/get/"+strconv.Itoa(ib.ID), n.inboundView(ib), nil)
	}
	for _, path := range []string{"clients/onlines", "clients/onlinesByGuid", "clients/lastOnline", "clients/activeInbounds", "clients/clientIpsByGuid"} {
		obj, err := n.post(nil, path, nil)
		cache("POST", path, obj, err)
	}
	n.views.Store(views)
}
