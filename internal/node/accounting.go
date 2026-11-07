package node

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

func (n *Node) collect() error {
	if n.core == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	counters, err := n.core.Stats(ctx)
	if err != nil {
		return err
	}
	now := time.Now().UnixMilli()
	for name, value := range counters {
		if value < 0 {
			continue
		}
		previous := n.previous[name]
		delta := value - previous
		if delta < 0 {
			delta = value
		}
		n.previous[name] = value
		if delta == 0 {
			continue
		}
		parts := strings.Split(name, ">>>")
		if len(parts) != 4 || parts[2] != "traffic" {
			continue
		}
		up := parts[3] == "uplink"
		if !up && parts[3] != "downlink" {
			continue
		}
		switch parts[0] {
		case "user":
			t := n.state.Traffic[parts[1]]
			if t == nil {
				continue
			}
			if up {
				t.Up += delta
			} else {
				t.Down += delta
			}
			t.LastOnline = now
			if t.ExpiryTime < 0 {
				expiry := now - t.ExpiryTime
				t.ExpiryTime = expiry
				for i := range n.state.Inbounds {
					clients := n.state.Inbounds[i].clients()
					for _, c := range clients {
						if str(c, "email") == t.Email {
							c["expiryTime"] = expiry
						}
					}
					n.state.Inbounds[i].setClients(clients)
				}
			}
		case "inbound":
			for i := range n.state.Inbounds {
				ib := &n.state.Inbounds[i]
				if ib.Tag == parts[1] {
					if up {
						ib.Up += delta
					} else {
						ib.Down += delta
					}
				}
			}
		}
	}
	return nil
}
func ensureTraffic(s *State) {
	for _, ib := range s.Inbounds {
		for _, c := range ib.clients() {
			email := str(c, "email")
			t := s.Traffic[email]
			if t == nil {
				t = &Traffic{Email: email}
				s.Traffic[email] = t
			}
			t.Enable = enabled(c)
			t.Total = num(c, "totalGB")
			t.ExpiryTime = num(c, "expiryTime")
			t.InboundID = ib.ID
			t.ID = ib.ID
		}
	}
}
func enforce(s *State) {
	now := time.Now().UnixMilli()
	for i := range s.Inbounds {
		ib := &s.Inbounds[i]
		if ib.Enable && ((ib.ExpiryTime > 0 && ib.ExpiryTime <= now) || (ib.Total > 0 && ib.Up+ib.Down >= ib.Total)) {
			ib.Enable = false
		}
		clients := ib.clients()
		for _, c := range clients {
			if !clientAllowed(*s, c, now) {
				c["enable"] = false
			}
		}
		ib.setClients(clients)
	}
	ensureTraffic(s)
}
func clientAllowed(s State, c Object, now int64) bool {
	if !enabled(c) {
		return false
	}
	expiry := num(c, "expiryTime")
	if expiry > 0 && expiry <= now {
		return false
	}
	limit := num(c, "totalGB")
	if limit <= 0 {
		return true
	}
	email := str(c, "email")
	if t := s.Traffic[email]; t != nil && t.Up+t.Down >= limit {
		return false
	}
	for _, rows := range s.Global {
		if g, ok := rows[email]; ok && g.ReceivedAt > now-86400000 && g.Up+g.Down >= limit {
			return false
		}
	}
	return true
}
func (n *Node) render(s State) ([]byte, error) {
	api := n.cfg.APIAddress
	if api == "" {
		api = "127.0.0.1:10085"
	}
	host, portText, err := net.SplitHostPort(api)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return nil, err
	}
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid API port")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("Xray API must listen on a loopback IP")
	}
	inbounds := []Object{}
	now := time.Now().UnixMilli()
	for _, ib := range s.Inbounds {
		if !ib.Enable || (ib.ExpiryTime > 0 && ib.ExpiryTime <= now) || (ib.Total > 0 && ib.Up+ib.Down >= ib.Total) {
			continue
		}
		settings := Object{}
		b, _ := json.Marshal(ib.Settings)
		_ = json.Unmarshal(b, &settings)
		clients := []Object{}
		for _, c := range ib.clients() {
			if !clientAllowed(s, c, now) {
				continue
			}
			out := Object{"email": str(c, "email"), "level": 0}
			switch ib.Protocol {
			case "vless":
				for _, k := range []string{"id", "flow", "reverse"} {
					if v, ok := c[k]; ok {
						out[k] = v
					}
				}
			case "vmess":
				// VMess has no panel-side security setting in server clients.
				out["id"] = c["id"]
				if v, ok := c["alterId"]; ok {
					out["alterId"] = v
				}
			case "trojan":
				out["password"] = c["password"]
			case "shadowsocks":
				out["password"] = c["password"]
				if v, ok := c["method"]; ok {
					out["method"] = v
				} else if v, ok := settings["method"]; ok {
					out["method"] = v
				}
			}
			clients = append(clients, out)
			if ib.Protocol == "vless" && string(ib.Extra["disableFlow"]) == "true" {
				delete(out, "flow")
			}
		}
		if len(clients) == 0 {
			continue
		}
		settings["clients"] = clients
		delete(settings, "encryption")
		listen := ib.Listen
		if listen == "" {
			listen = "0.0.0.0"
		}
		inbound := Object{"tag": ib.Tag, "listen": listen, "port": ib.Port, "protocol": ib.Protocol, "settings": settings}
		if len(ib.StreamSettings) > 0 {
			inbound["streamSettings"] = ib.StreamSettings
		}
		if len(ib.Sniffing) > 0 {
			inbound["sniffing"] = ib.Sniffing
		}
		inbounds = append(inbounds, inbound)
	}
	return json.Marshal(Object{
		"log": Object{"loglevel": "warning"}, "stats": Object{},
		"api":      Object{"tag": "angelo-api", "listen": api, "services": []string{"StatsService"}},
		"policy":   Object{"levels": Object{"0": Object{"statsUserUplink": true, "statsUserDownlink": true, "bufferSize": 4}}, "system": Object{"statsInboundUplink": true, "statsInboundDownlink": true}},
		"inbounds": inbounds, "outbounds": []Object{{"tag": "direct", "protocol": "freedom"}},
	})
}
func (n *Node) reconcile(ctx context.Context) error {
	ensureTraffic(&n.state)
	enforce(&n.state)
	data, err := n.render(n.state)
	if err != nil {
		return err
	}
	if bytes.Equal(data, n.active) {
		return nil
	}
	if n.core != nil {
		if err = n.replace(ctx, data); err != nil {
			return err
		}
		n.previous = map[string]int64{}
	}
	n.active = data
	return nil
}
func (n *Node) commit(ctx context.Context, next State) error {
	if err := validateState(&next, n.cfg.MaxInbounds, n.cfg.MaxClients); err != nil {
		return err
	}
	ensureTraffic(&next)
	enforce(&next)
	data, err := n.render(next)
	if err != nil {
		return err
	}
	old := n.state
	oldConfig := n.active
	changed := !bytes.Equal(data, oldConfig)
	if changed && n.core != nil {
		if err = n.replace(ctx, data); err != nil {
			n.previous = map[string]int64{}
			return err
		}
		n.previous = map[string]int64{}
	}
	n.state = next
	if err = n.save(); err != nil {
		n.state = old
		if changed && n.core != nil {
			if rollback := n.replace(context.Background(), oldConfig); rollback != nil {
				n.lastErr = fmt.Sprintf("save failed: %v; rollback failed: %v", err, rollback)
			}
		}
		return err
	}
	n.active = data
	return nil
}
func (n *Node) inboundView(ib Inbound) Inbound {
	ib.ClientStats = []Traffic{}
	for _, c := range ib.clients() {
		if t := n.state.Traffic[str(c, "email")]; t != nil {
			copy := *t
			copy.InboundID = ib.ID
			copy.Enable = clientAllowed(n.state, c, time.Now().UnixMilli())
			ib.ClientStats = append(ib.ClientStats, copy)
		}
	}
	return ib
}
