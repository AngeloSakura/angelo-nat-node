package node

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Object map[string]any

func (o *Object) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		b = []byte(s)
	}
	if len(b) == 0 || string(b) == "null" {
		*o = Object{}
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return err
	}
	*o = Object(m)
	return nil
}

type Inbound struct {
	ID             int                        `json:"id"`
	Up             int64                      `json:"up"`
	Down           int64                      `json:"down"`
	Total          int64                      `json:"total"`
	Enable         bool                       `json:"enable"`
	ExpiryTime     int64                      `json:"expiryTime"`
	Remark         string                     `json:"remark"`
	Listen         string                     `json:"listen"`
	Port           int                        `json:"port"`
	Protocol       string                     `json:"protocol"`
	Tag            string                     `json:"tag"`
	Settings       Object                     `json:"settings"`
	StreamSettings Object                     `json:"streamSettings"`
	Sniffing       Object                     `json:"sniffing"`
	ClientStats    []Traffic                  `json:"clientStats"`
	Extra          map[string]json.RawMessage `json:"-"`
}

type inboundAlias Inbound

func (i *Inbound) UnmarshalJSON(b []byte) error {
	var a inboundAlias
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	*i = Inbound(a)
	return json.Unmarshal(b, &i.Extra)
}
func (i Inbound) MarshalJSON() ([]byte, error) {
	b, err := json.Marshal(inboundAlias(i))
	if err != nil {
		return nil, err
	}
	m := map[string]json.RawMessage{}
	for k, v := range i.Extra {
		m[k] = v
	}
	var known map[string]json.RawMessage
	_ = json.Unmarshal(b, &known)
	for k, v := range known {
		m[k] = v
	}
	delete(m, "nodeId")
	delete(m, "originNodeGuid")
	return json.Marshal(m)
}
func (i *Inbound) clients() []Object {
	raw, _ := json.Marshal(i.Settings["clients"])
	var out []Object
	_ = json.Unmarshal(raw, &out)
	return out
}
func (i *Inbound) setClients(c []Object) {
	if i.Settings == nil {
		i.Settings = Object{}
	}
	i.Settings["clients"] = c
}
func str(m Object, k string) string { s, _ := m[k].(string); return s }
func num(m Object, k string) int64 {
	switch v := m[k].(type) {
	case json.Number:
		n, _ := v.Int64()
		return n
	case float64:
		return int64(v)
	case int64:
		return v
	case int:
		return int64(v)
	}
	return 0
}
func enabled(m Object) bool { v, ok := m["enable"].(bool); return !ok || v }

type Traffic struct {
	ID         int    `json:"id"`
	InboundID  int    `json:"inboundId"`
	Email      string `json:"email"`
	Enable     bool   `json:"enable"`
	Up         int64  `json:"up"`
	Down       int64  `json:"down"`
	Total      int64  `json:"total"`
	ExpiryTime int64  `json:"expiryTime"`
	LastOnline int64  `json:"lastOnline"`
}
type GlobalUsage struct {
	Up         int64 `json:"up"`
	Down       int64 `json:"down"`
	ReceivedAt int64 `json:"receivedAt"`
}
type State struct {
	Schema   int                               `json:"schema"`
	GUID     string                            `json:"guid"`
	NextID   int                               `json:"nextId"`
	Inbounds []Inbound                         `json:"inbounds"`
	Traffic  map[string]*Traffic               `json:"traffic"`
	Global   map[string]map[string]GlobalUsage `json:"global"`
}

func copyState(s State) State {
	b, _ := json.Marshal(s)
	var out State
	_ = json.Unmarshal(b, &out)
	return out
}
func atomicJSON(path string, value any) error {
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return atomicWrite(path, b, 0600)
}
func atomicWrite(path string, b []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(name, path); err != nil {
		return err
	}
	if d, e := os.Open(filepath.Dir(path)); e == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
func validateState(s *State, maxInbounds, maxClients int) error {
	if len(s.Inbounds) > maxInbounds {
		return fmt.Errorf("maximum %d inbounds", maxInbounds)
	}
	tags := map[string]bool{}
	users := map[string]bool{}
	for _, ib := range s.Inbounds {
		if ib.Port < 1 || ib.Port > 65535 {
			return fmt.Errorf("port must be 1..65535")
		}
		if ib.Tag == "" || len(ib.Tag) > 128 || strings.Contains(ib.Tag, ">>>") || strings.HasPrefix(ib.Tag, "angelo-") {
			return fmt.Errorf("invalid or reserved inbound tag")
		}
		if tags[ib.Tag] {
			return fmt.Errorf("duplicate inbound tag %q", ib.Tag)
		}
		tags[ib.Tag] = true
		switch ib.Protocol {
		case "vless", "vmess", "trojan", "shadowsocks":
		default:
			return fmt.Errorf("protocol %q is not supported; use vless, vmess, trojan or shadowsocks", ib.Protocol)
		}
		if ib.Settings == nil {
			return fmt.Errorf("settings must be an object")
		}
		clients := ib.clients()
		emails := map[string]bool{}
		for _, c := range clients {
			email := str(c, "email")
			if email == "" || len(email) > 256 || strings.Contains(email, ">>>") {
				return fmt.Errorf("each client requires a valid email")
			}
			if emails[email] {
				return fmt.Errorf("duplicate email in inbound")
			}
			emails[email] = true
			users[email] = true
			if num(c, "totalGB") < 0 {
				return fmt.Errorf("totalGB must be nonnegative bytes")
			}
			if num(c, "limitIp") > 0 {
				return fmt.Errorf("IP limits are not implemented; set limitIp=0")
			}
			if ib.Protocol == "vless" || ib.Protocol == "vmess" {
				if str(c, "id") == "" {
					return fmt.Errorf("client id is required")
				}
			} else if str(c, "password") == "" {
				return fmt.Errorf("client password is required")
			}
		}
	}
	if len(users) > maxClients {
		return fmt.Errorf("maximum %d unique clients", maxClients)
	}
	return nil
}
