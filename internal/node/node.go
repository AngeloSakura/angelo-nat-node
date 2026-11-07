package node

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	Listen          string `json:"listen"`
	Token           string `json:"token"`
	BasePath        string `json:"basePath"`
	StateDir        string `json:"stateDir"`
	XrayPath        string `json:"xrayPath"`
	APIAddress      string `json:"apiAddress"`
	TLSCert         string `json:"tlsCert"`
	TLSKey          string `json:"tlsKey"`
	PollSeconds     int    `json:"pollSeconds"`
	MaxClients      int    `json:"maxClients"`
	MaxInbounds     int    `json:"maxInbounds"`
	XrayMemoryLimit string `json:"xrayMemoryLimit"`
	DirectSettings  Object `json:"directOutboundSettings,omitempty"`
}
type Runtime interface {
	Apply(context.Context, []byte) error
	Stats(context.Context) (map[string]int64, error)
	Running() bool
	Version() string
	Stop() error
}
type Node struct {
	mu       sync.Mutex
	cfg      Config
	state    State
	core     Runtime
	previous map[string]int64
	active   []byte
	lastErr  string
	started  time.Time
	views    atomic.Value
	requests chan struct{}
	closed   bool
}

func Open(cfg Config, core Runtime) (*Node, error) {
	return open(cfg, core, true)
}

// Check validates existing state without initializing, saving, or starting Xray.
func Check(cfg Config) error {
	n, err := open(cfg, nil, false)
	if err != nil {
		return err
	}
	_, err = n.render(n.state)
	return err
}
func open(cfg Config, core Runtime, create bool) (*Node, error) {
	if len(cfg.Token) < 32 {
		return nil, fmt.Errorf("token must contain at least 32 characters")
	}
	if cfg.MaxClients == 0 {
		cfg.MaxClients = 64
	}
	if cfg.MaxInbounds == 0 {
		cfg.MaxInbounds = 16
	}
	if cfg.BasePath == "" {
		cfg.BasePath = "/"
	}
	if !filepath.IsAbs(cfg.StateDir) || strings.ContainsAny(cfg.StateDir, "\r\n\x00") {
		return nil, fmt.Errorf("stateDir must be an absolute single-line path")
	}
	if cfg.MaxClients < 1 || cfg.MaxInbounds < 1 {
		return nil, fmt.Errorf("capacity limits must be positive")
	}
	if create {
		if err := os.MkdirAll(cfg.StateDir, 0700); err != nil {
			return nil, err
		}
	}
	n := &Node{cfg: cfg, core: core, previous: map[string]int64{}, started: time.Now(), requests: make(chan struct{}, 4)}
	b, err := os.ReadFile(filepath.Join(cfg.StateDir, "state.json"))
	if os.IsNotExist(err) && create {
		id := make([]byte, 16)
		if _, err = rand.Read(id); err != nil {
			return nil, err
		}
		n.state = State{Schema: 1, GUID: hex.EncodeToString(id), NextID: 1, Inbounds: []Inbound{}, Traffic: map[string]*Traffic{}, Global: map[string]map[string]GlobalUsage{}}
		err = n.save()
	} else if err == nil {
		err = json.Unmarshal(b, &n.state)
	}
	if err != nil {
		return nil, err
	}
	if n.state.Schema != 1 || n.state.Traffic == nil || n.state.Global == nil || n.state.GUID == "" {
		return nil, fmt.Errorf("invalid state schema")
	}
	if err = validateState(&n.state, cfg.MaxInbounds, cfg.MaxClients); err != nil {
		return nil, err
	}
	n.refreshViews()
	return n, nil
}
func (n *Node) save() error { return atomicJSON(filepath.Join(n.cfg.StateDir, "state.json"), n.state) }
func (n *Node) replace(ctx context.Context, data []byte) error {
	if n.core == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	defer func() { n.previous = map[string]int64{} }()
	return n.core.Apply(ctx, data)
}
func (n *Node) Start(ctx context.Context) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	defer n.refreshViews()
	data, err := n.render(n.state)
	if err != nil {
		return err
	}
	if n.core != nil {
		if err = n.replace(ctx, data); err != nil {
			return err
		}
	}
	n.active = data
	return nil
}
func (n *Node) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.closed {
		return nil
	}
	n.closed = true
	_ = n.collect()
	err := n.save()
	if n.core != nil {
		if e := n.core.Stop(); err == nil {
			err = e
		}
	}
	return err
}
func (n *Node) Run(ctx context.Context) {
	interval := n.cfg.PollSeconds
	if interval < 2 {
		interval = 10
	}
	timer := time.NewTicker(time.Duration(interval) * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			n.mu.Lock()
			if n.closed || ctx.Err() != nil {
				n.mu.Unlock()
				return
			}
			if n.core != nil && !n.core.Running() {
				n.previous = map[string]int64{}
				data, _ := n.render(n.state)
				if err := n.replace(ctx, data); err != nil {
					n.lastErr = err.Error()
				} else {
					n.lastErr = ""
					n.active = data
				}
			} else if err := n.collect(); err != nil {
				n.lastErr = err.Error()
			} else {
				if err = n.reconcile(ctx); err != nil {
					n.lastErr = err.Error()
				} else {
					n.lastErr = ""
				}
			}
			if err := n.save(); err != nil {
				n.lastErr = err.Error()
			}
			n.refreshViews()
			n.mu.Unlock()
		}
	}
}
