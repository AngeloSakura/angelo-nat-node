package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/AngeloSakura/angelo-nat-node/internal/node"
)

func certificate(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(b)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("invalid TLS certificate")
	}
	if _, err = x509.ParseCertificate(block.Bytes); err != nil {
		return nil, err
	}
	return block.Bytes, nil
}
func showFingerprint(path string) error {
	if path == "" {
		return nil
	}
	der, err := certificate(path)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(der)
	fmt.Printf("TLS SHA256 fingerprint: %s\n", hex.EncodeToString(sum[:]))
	return nil
}
func healthCheck(cfg node.Config) error {
	host, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return err
	}
	if host == "" || host == "0.0.0.0" {
		host = "127.0.0.1"
	}
	if host == "::" {
		host = "::1"
	}
	scheme := "http"
	transport := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: time.Second}).DialContext, DisableKeepAlives: true}
	if cfg.TLSCert != "" {
		scheme = "https"
		pinned, err := certificate(cfg.TLSCert)
		if err != nil {
			return err
		}
		// Exact locally configured leaf pin replaces public CA/hostname trust.
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true, VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 || !bytes.Equal(cs.PeerCertificates[0].Raw, pinned) {
				return fmt.Errorf("local API certificate does not match config")
			}
			return nil
		}}
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, endpoint := range []string{"server/health", "inbounds/list"} {
		address := scheme + "://" + net.JoinHostPort(host, port) + "/" + strings.Trim(cfg.BasePath, "/")
		address = strings.TrimRight(address, "/") + "/panel/api/" + endpoint
		req, err := http.NewRequest("GET", address, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+cfg.Token)
		response, err := client.Do(req)
		if err != nil {
			return err
		}
		b, err := io.ReadAll(io.LimitReader(response.Body, 2<<20))
		response.Body.Close()
		if err != nil {
			return err
		}
		var envelope struct {
			Success bool            `json:"success"`
			Obj     json.RawMessage `json:"obj"`
		}
		if response.StatusCode != 200 || json.Unmarshal(b, &envelope) != nil || !envelope.Success {
			return fmt.Errorf("local API health failed: %s", endpoint)
		}
		if endpoint == "server/health" {
			var status struct {
				Xray struct {
					State string `json:"state"`
				} `json:"xray"`
			}
			if json.Unmarshal(envelope.Obj, &status) != nil || status.Xray.State != "running" {
				return fmt.Errorf("Xray is not running")
			}
		} else {
			var inbounds []json.RawMessage
			if json.Unmarshal(envelope.Obj, &inbounds) != nil || inbounds == nil {
				return fmt.Errorf("invalid inbound snapshot")
			}
		}
	}
	fmt.Println("Node API and Xray healthy")
	return nil
}
