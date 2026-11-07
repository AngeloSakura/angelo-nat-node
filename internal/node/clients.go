package node

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

func mutateClients(s *State, path string, query url.Values, raw []byte) error {
	switch {
	case path == "clients/add":
		var p struct {
			Client     Object `json:"client"`
			InboundIDs []int  `json:"inboundIds"`
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return err
		}
		if str(p.Client, "email") == "" || len(p.InboundIDs) == 0 {
			return fmt.Errorf("client.email and inboundIds are required")
		}
		for _, id := range p.InboundIDs {
			ib := findInbound(s, id)
			if ib == nil {
				return fmt.Errorf("inbound not found")
			}
			clients := ib.clients()
			for _, c := range clients {
				if str(c, "email") == str(p.Client, "email") {
					return fmt.Errorf("client already exists")
				}
			}
			ib.setClients(append(clients, p.Client))
		}
	case strings.HasPrefix(path, "clients/update/"):
		email := strings.TrimPrefix(path, "clients/update/")
		var p Object
		if err := json.Unmarshal(raw, &p); err != nil {
			return err
		}
		if str(p, "email") == "" {
			return fmt.Errorf("email is required")
		}
		ids := map[int]bool{}
		for _, v := range strings.Split(query.Get("inboundIds"), ",") {
			if v != "" {
				id, err := strconv.Atoi(v)
				if err != nil {
					return err
				}
				ids[id] = true
			}
		}
		found := false
		newEmail := str(p, "email")
		for i := range s.Inbounds {
			ib := &s.Inbounds[i]
			if newEmail == email && len(ids) > 0 && !ids[ib.ID] {
				continue
			}
			clients := ib.clients()
			for j, c := range clients {
				if str(c, "email") == email {
					clients[j] = p
					found = true
				}
			}
			ib.setClients(clients)
		}
		if !found {
			return fmt.Errorf("client not found")
		}
		if newEmail != email {
			if s.Traffic[newEmail] != nil {
				return fmt.Errorf("new email already exists")
			}
			if t := s.Traffic[email]; t != nil {
				copy := *t
				copy.Email = newEmail
				s.Traffic[newEmail] = &copy
				delete(s.Traffic, email)
			}
			for _, rows := range s.Global {
				if g, ok := rows[email]; ok {
					rows[newEmail] = g
					delete(rows, email)
				}
			}
		}
	case strings.HasPrefix(path, "clients/del/") || strings.HasSuffix(path, "/detach"):
		email := strings.TrimPrefix(path, "clients/del/")
		if strings.HasPrefix(path, "clients/del/") {
			delete(s.Traffic, email)
			for _, rows := range s.Global {
				delete(rows, email)
			}
		}
		ids := map[int]bool{}
		if strings.HasSuffix(path, "/detach") {
			email = strings.TrimSuffix(strings.TrimPrefix(path, "clients/"), "/detach")
			var p struct {
				InboundIDs []int `json:"inboundIds"`
			}
			if err := json.Unmarshal(raw, &p); err != nil {
				return err
			}
			if len(p.InboundIDs) == 0 {
				return fmt.Errorf("inboundIds are required")
			}
			for _, id := range p.InboundIDs {
				ids[id] = true
			}
		}
		for i := range s.Inbounds {
			ib := &s.Inbounds[i]
			if len(ids) > 0 && !ids[ib.ID] {
				continue
			}
			clients := []Object{}
			for _, c := range ib.clients() {
				if str(c, "email") != email {
					clients = append(clients, c)
				}
			}
			ib.setClients(clients)
		}
	case strings.HasPrefix(path, "clients/resetTraffic/") || path == "clients/bulkResetTraffic":
		emails := []string{strings.TrimPrefix(path, "clients/resetTraffic/")}
		if path == "clients/bulkResetTraffic" {
			var p struct {
				Emails []string `json:"emails"`
			}
			if err := json.Unmarshal(raw, &p); err != nil {
				return err
			}
			emails = p.Emails
		}
		for _, email := range emails {
			if t := s.Traffic[email]; t != nil {
				t.Up = 0
				t.Down = 0
				t.Enable = true
			}
			for _, rows := range s.Global {
				delete(rows, email)
			}
			for i := range s.Inbounds {
				clients := s.Inbounds[i].clients()
				for _, c := range clients {
					if str(c, "email") == email {
						c["enable"] = true
					}
				}
				s.Inbounds[i].setClients(clients)
			}
		}
	default:
		return fmt.Errorf("unsupported client operation %s", path)
	}
	return nil
}
func findInbound(s *State, id int) *Inbound {
	for i := range s.Inbounds {
		if s.Inbounds[i].ID == id {
			return &s.Inbounds[i]
		}
	}
	return nil
}
