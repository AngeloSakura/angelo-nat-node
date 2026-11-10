package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestXrayReleaseMenu(t *testing.T) {
	r := []xrayRelease{{Tag: "v26.11.9", Prerelease: true}, {Tag: "v26.10.31"}}
	var out bytes.Buffer
	selected, err := chooseXrayRelease(bufio.NewReader(strings.NewReader("v26.11.9\n3\n2\n")), &out, r, "26.10.31")
	if err != nil || selected.Tag != r[1].Tag || !strings.Contains(out.String(), "[当前]") || !strings.Contains(out.String(), "[预发布]") || strings.Count(out.String(), "无效序号") != 2 {
		t.Fatalf("selection: %v, %v; output %s", selected, err, out.String())
	}
	selected, err = chooseXrayRelease(bufio.NewReader(strings.NewReader("0\n")), io.Discard, r, "")
	if err != nil || selected != nil {
		t.Fatalf("cancel: %v %v", selected, err)
	}
	_, err = chooseXrayRelease(bufio.NewReader(strings.NewReader("")), io.Discard, r, "")
	if err != io.EOF {
		t.Fatalf("EOF: %v", err)
	}
}

func TestFetchXrayReleases(t *testing.T) {
	asset := xrayAsset{Name: "Xray-linux-64.zip"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		json.NewEncoder(w).Encode([]xrayRelease{
			{Tag: "v26.11.9", Prerelease: true, Assets: []xrayAsset{asset}},
			{Tag: "v26.10.31", Assets: []xrayAsset{asset}},
			{Tag: "v26.10.31", Assets: []xrayAsset{asset}},
			{Tag: "v26.6.26", Assets: []xrayAsset{asset}},
			{Tag: "v99.1.1", Draft: true, Assets: []xrayAsset{asset}},
			{Tag: "v26.6.27", Assets: []xrayAsset{asset}},
			{Tag: "v26.8.1"}, {Tag: "../../bad", Assets: []xrayAsset{asset}},
		})
	}))
	defer server.Close()
	got, err := fetchXrayReleases(context.Background(), server.Client(), server.URL, asset.Name)
	if err != nil || len(got) != 3 || got[0].Tag != "v26.11.9" || got[2].Tag != "v26.6.27" {
		t.Fatalf("got %v %v", got, err)
	}
	for _, status := range []int{403, 429, 500} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
		_, err = fetchXrayReleases(context.Background(), s.Client(), s.URL, asset.Name)
		s.Close()
		if err == nil {
			t.Fatalf("accepted status %d", status)
		}
	}
}

type xrayTransport func(*http.Request) (*http.Response, error)

func (f xrayTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestPrepareXray(t *testing.T) {
	var archive bytes.Buffer
	z := zip.NewWriter(&archive)
	w, _ := z.Create("xray")
	w.Write([]byte("official-binary-fixture"))
	z.Close()
	digest := fmt.Sprintf("%x", sha256.Sum256(archive.Bytes()))
	name := "Xray-linux-64.zip"
	url := "https://github.com/XTLS/Xray-core/releases/download/v26.10.31/" + name
	for _, tc := range []struct {
		name, digest, dgst string
		wantErr            bool
	}{
		{"digest", "sha256:" + digest, "", false},
		{"fallback", "", "SHA2-256 (" + name + ") = " + digest + "\n", false},
		{"checksum mismatch", "sha256:" + strings.Repeat("0", 64), "", true},
		{"missing checksum", "", "untrusted", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: xrayTransport(func(r *http.Request) (*http.Response, error) {
				body := archive.Bytes()
				if strings.HasSuffix(r.URL.Path, ".dgst") {
					body = []byte(tc.dgst)
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(body)), Header: make(http.Header)}, nil
			})}
			r := xrayRelease{Tag: "v26.10.31", Assets: []xrayAsset{{Name: name, URL: url, Digest: tc.digest}, {Name: name + ".dgst", URL: url + ".dgst"}}}
			path, err := prepareXray(context.Background(), client, r, name, t.TempDir())
			if (err != nil) != tc.wantErr {
				t.Fatalf("prepare: %v", err)
			}
			if err == nil {
				b, _ := os.ReadFile(path)
				if string(b) != "official-binary-fixture" {
					t.Fatal("wrong executable")
				}
			}
		})
	}
	for _, raw := range []string{"http://github.com/XTLS/Xray-core/releases/download/v26.10.31/" + name, url + "?redirect=1", strings.Replace(url, "github.com", "evil.example", 1)} {
		if validXrayDownload(raw, "v26.10.31", name) {
			t.Fatalf("accepted %s", raw)
		}
	}
}

func TestExtractXrayRejectsMissingDuplicateAndSymlink(t *testing.T) {
	for _, kind := range []string{"missing", "duplicate", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			archive := filepath.Join(dir, "archive.zip")
			f, _ := os.Create(archive)
			z := zip.NewWriter(f)
			h := &zip.FileHeader{Name: "xray"}
			h.SetMode(0755)
			if kind == "missing" {
				h.Name = "../xray"
			}
			if kind == "symlink" {
				h.SetMode(os.ModeSymlink | 0755)
			}
			w, _ := z.CreateHeader(h)
			w.Write([]byte("fixture"))
			if kind == "duplicate" {
				w, _ = z.Create("xray")
				w.Write([]byte("another"))
			}
			z.Close()
			f.Close()
			if _, err := extractXray(archive, filepath.Join(dir, "xray")); err == nil {
				t.Fatal("accepted unsafe archive")
			}
		})
	}
}
