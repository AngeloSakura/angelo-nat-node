package node

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const maxBody = 1 << 20

func reply(w http.ResponseWriter, obj any, err error) {
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(Object{"success": err == nil, "msg": msg, "obj": obj})
}
func (n *Node) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	prefix := "/" + strings.Trim(n.cfg.BasePath, "/")
	if prefix != "/" {
		prefix += "/"
	}
	prefix += "panel/api/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		http.NotFound(w, r)
		return
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	want := sha256.Sum256([]byte(n.cfg.Token))
	got := sha256.Sum256([]byte(token))
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || subtle.ConstantTimeCompare(want[:], got[:]) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != "GET" && r.Method != "POST" {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if encoding := r.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		http.Error(w, "unsupported encoding", http.StatusUnsupportedMediaType)
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}
	if expected := r.Header.Get("X-Config-Sha256"); expected != "" {
		sum := sha256.Sum256(raw)
		if subtle.ConstantTimeCompare([]byte(strings.ToLower(expected)), []byte(hex.EncodeToString(sum[:]))) != 1 {
			http.Error(w, "body checksum mismatch", http.StatusBadRequest)
			return
		}
	}
	route := strings.TrimPrefix(r.URL.Path, prefix)
	if cached, ok := n.views.Load().(map[string][]byte); ok {
		if b, found := cached[r.Method+" "+route]; found {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Cache-Control", "no-store")
			_, _ = w.Write(b)
			return
		}
	}
	if !n.mu.TryLock() {
		w.WriteHeader(http.StatusServiceUnavailable)
		reply(w, nil, fmt.Errorf("configuration update in progress; retry"))
		return
	}
	defer n.mu.Unlock()
	defer n.refreshViews()
	if r.Method == "GET" {
		obj, err := n.get(route)
		reply(w, obj, err)
		return
	}
	obj, err := n.post(r, route, raw)
	reply(w, obj, err)
}
func (n *Node) get(path string) (any, error) {
	switch path {
	case "server/status":
		state := "stopped"
		version := ""
		if n.core != nil {
			version = n.core.Version()
			if n.core.Running() {
				state = "running"
			}
		}
		current, total := memoryUsage()
		return Object{"cpu": 0, "unavailableMetrics": []string{"cpu", "netIO"}, "mem": Object{"current": current, "total": total}, "uptime": int64(time.Since(n.started).Seconds()), "panelVersion": "angelo-nat-node " + Version, "panelGuid": n.state.GUID, "netIO": Object{"up": 0, "down": 0}, "xray": Object{"version": version, "state": state, "errorMsg": n.lastErr}}, nil
	case "inbounds/list":
		out := []Inbound{}
		for _, ib := range n.state.Inbounds {
			out = append(out, n.inboundView(ib))
		}
		return out, nil
	case "server/descendants", "hosts/list", "server/clientIps":
		return []any{}, nil
	case "server/getWebCertFiles":
		return Object{"webCertFile": n.cfg.TLSCert, "webKeyFile": n.cfg.TLSKey}, nil
	}
	if strings.HasPrefix(path, "inbounds/get/") {
		id, _ := strconv.Atoi(strings.TrimPrefix(path, "inbounds/get/"))
		for _, ib := range n.state.Inbounds {
			if ib.ID == id {
				return n.inboundView(ib), nil
			}
		}
		return nil, fmt.Errorf("inbound not found")
	}
	return nil, fmt.Errorf("unsupported endpoint %s", path)
}
func parseInbound(r *http.Request, raw []byte) (Inbound, error) {
	var ib Inbound
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		return ib, json.Unmarshal(raw, &ib)
	}
	values, err := url.ParseQuery(string(raw))
	if err != nil {
		return ib, err
	}
	m := map[string]any{}
	ints := map[string]bool{"id": true, "up": true, "down": true, "total": true, "expiryTime": true, "port": true, "subSortIndex": true, "trafficResetDay": true}
	bools := map[string]bool{"enable": true, "excludeFromSub": true, "disableFlow": true}
	for k, v := range values {
		if len(v) != 1 {
			return ib, fmt.Errorf("duplicate field %s", k)
		}
		switch {
		case ints[k]:
			n, e := strconv.ParseInt(v[0], 10, 64)
			if e != nil {
				return ib, e
			}
			m[k] = n
		case bools[k]:
			b, e := strconv.ParseBool(v[0])
			if e != nil {
				return ib, e
			}
			m[k] = b
		default:
			m[k] = v[0]
		}
	}
	data, _ := json.Marshal(m)
	err = json.Unmarshal(data, &ib)
	return ib, err
}
func (n *Node) post(r *http.Request, path string, raw []byte) (any, error) {
	now := time.Now().UnixMilli()
	switch path {
	case "clients/onlines", "clients/onlinesByGuid", "clients/lastOnline", "clients/activeInbounds", "clients/clientIpsByGuid":
		online := []string{}
		last := map[string]int64{}
		for email, t := range n.state.Traffic {
			last[email] = t.LastOnline
			if t.LastOnline > now-30000 {
				online = append(online, email)
			}
		}
		switch path {
		case "clients/onlines":
			return online, nil
		case "clients/onlinesByGuid":
			return map[string][]string{n.state.GUID: online}, nil
		case "clients/lastOnline":
			return last, nil
		case "clients/clientIpsByGuid":
			return map[string]any{}, nil
		default:
			return nil, fmt.Errorf("active inbound attribution unavailable")
		}
	case "server/clientIps":
		return nil, fmt.Errorf("IP limit synchronization is not supported")
	}
	if err := n.collect(); err != nil && n.core != nil && n.core.Running() {
		return nil, fmt.Errorf("cannot checkpoint Xray traffic: %w", err)
	}
	next := copyState(n.state)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	var result any
	switch {
	case path == "inbounds/add" || strings.HasPrefix(path, "inbounds/update/"):
		ib, err := parseInbound(r, raw)
		if err != nil {
			return nil, err
		}
		if path == "inbounds/add" {
			ib.ID = next.NextID
			next.NextID++
			ib.Up = 0
			ib.Down = 0
			next.Inbounds = append(next.Inbounds, ib)
		} else {
			id, _ := strconv.Atoi(strings.TrimPrefix(path, "inbounds/update/"))
			found := false
			for i, old := range next.Inbounds {
				if old.ID == id {
					ib.ID = id
					ib.Up = old.Up
					ib.Down = old.Down
					next.Inbounds[i] = ib
					found = true
					break
				}
			}
			if !found {
				return nil, fmt.Errorf("inbound not found")
			}
		}
		result = ib
	case strings.HasPrefix(path, "inbounds/del/"):
		id, _ := strconv.Atoi(strings.TrimPrefix(path, "inbounds/del/"))
		found := false
		for i, ib := range next.Inbounds {
			if ib.ID == id {
				next.Inbounds = append(next.Inbounds[:i], next.Inbounds[i+1:]...)
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("inbound not found")
		}
	case path == "inbounds/pushClientTraffics":
		var payload struct {
			MasterGUID string    `json:"masterGuid"`
			Traffics   []Traffic `json:"traffics"`
		}
		if err := json.Unmarshal(raw, &payload); err != nil {
			return nil, err
		}
		if payload.MasterGUID == "" || len(payload.MasterGUID) > 64 || len(payload.Traffics) > n.cfg.MaxClients {
			return nil, fmt.Errorf("invalid global traffic payload")
		}
		if _, ok := next.Global[payload.MasterGUID]; !ok && len(next.Global) >= 4 {
			return nil, fmt.Errorf("maximum four masters")
		}
		rows := next.Global[payload.MasterGUID]
		if rows == nil {
			rows = map[string]GlobalUsage{}
		}
		for _, t := range payload.Traffics {
			if t.Up < 0 || t.Down < 0 {
				return nil, fmt.Errorf("negative usage")
			}
			if next.Traffic[t.Email] != nil {
				rows[t.Email] = GlobalUsage{Up: t.Up, Down: t.Down, ReceivedAt: now}
			}
		}
		next.Global[payload.MasterGUID] = rows
	case path == "inbounds/resetAllTraffics":
		for i := range next.Inbounds {
			next.Inbounds[i].Up = 0
			next.Inbounds[i].Down = 0
			markReset(&next.Inbounds[i], now)
		}
	case strings.HasPrefix(path, "inbounds/") && (strings.HasSuffix(path, "/resetTraffic") || strings.HasSuffix(path, "/subSortIndex")):
		parts := strings.Split(path, "/")
		id, _ := strconv.Atoi(parts[1])
		found := false
		for i := range next.Inbounds {
			ib := &next.Inbounds[i]
			if ib.ID != id {
				continue
			}
			found = true
			if parts[2] == "resetTraffic" {
				ib.Up = 0
				ib.Down = 0
				markReset(ib, now)
			} else {
				values, e := url.ParseQuery(string(raw))
				if e != nil {
					return nil, e
				}
				index, e := strconv.Atoi(values.Get("subSortIndex"))
				if e != nil {
					return nil, e
				}
				b, _ := json.Marshal(index)
				if ib.Extra == nil {
					ib.Extra = map[string]json.RawMessage{}
				}
				ib.Extra["subSortIndex"] = b
			}
		}
		if !found {
			return nil, fmt.Errorf("inbound not found")
		}
	case strings.HasPrefix(path, "clients/"):
		if err := mutateClients(&next, path, r.URL.Query(), raw); err != nil {
			return nil, err
		}
	case path == "server/restartXrayService":
		if n.core == nil {
			return nil, fmt.Errorf("Xray runtime unavailable")
		}
		if err := n.replace(ctx, n.active); err != nil {
			return nil, err
		}
		n.previous = map[string]int64{}
		return nil, n.save()
	default:
		return nil, fmt.Errorf("unsupported endpoint %s", path)
	}
	if err := n.commit(ctx, next); err != nil {
		return nil, err
	}
	return result, nil
}
