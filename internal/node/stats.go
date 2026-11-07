package node

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"

	"golang.org/x/net/http2"
)

// Xray's stable QueryStats protobuf needs only two scalar fields; no core is linked into the agent.
type statsClient struct {
	client    *http.Client
	transport *http2.Transport
	address   string
}

func newStatsClient(address string) *statsClient {
	transport := &http2.Transport{AllowHTTP: true, DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}}
	return &statsClient{client: &http.Client{Transport: transport}, transport: transport, address: address}
}
func (c *statsClient) query(ctx context.Context) (map[string]int64, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", "http://"+c.address+"/xray.app.stats.command.StatsService/QueryStats", bytes.NewReader([]byte{0, 0, 0, 0, 0}))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/grpc")
	req.Header.Set("TE", "trailers")
	response, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 512))
		return nil, fmt.Errorf("stats HTTP %d: %s", response.StatusCode, body)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxBody {
		return nil, fmt.Errorf("stats response too large")
	}
	status := response.Trailer.Get("Grpc-Status")
	if status == "" {
		status = response.Header.Get("Grpc-Status")
	}
	if status != "0" {
		return nil, fmt.Errorf("stats gRPC status %q", status)
	}
	if len(body) < 5 || body[0] != 0 || int(binary.BigEndian.Uint32(body[1:5])) != len(body)-5 {
		return nil, fmt.Errorf("invalid gRPC frame")
	}
	counters := map[string]int64{}
	err = walkProto(body[5:], func(field, wire int, b []byte, v uint64) error {
		if field != 1 || wire != 2 {
			return nil
		}
		var name string
		var value int64
		if err := walkProto(b, func(f, w int, data []byte, n uint64) error {
			if f == 1 && w == 2 {
				name = string(data)
			}
			if f == 2 && w == 0 {
				value = int64(n)
			}
			return nil
		}); err != nil {
			return err
		}
		if name != "" {
			counters[name] = value
		}
		return nil
	})
	return counters, err
}
func walkProto(b []byte, visit func(int, int, []byte, uint64) error) error {
	for len(b) > 0 {
		key, n := binary.Uvarint(b)
		if n <= 0 {
			return fmt.Errorf("invalid protobuf tag")
		}
		b = b[n:]
		field, wire := int(key>>3), int(key&7)
		if field == 0 {
			return fmt.Errorf("invalid protobuf field")
		}
		var data []byte
		var value uint64
		switch wire {
		case 0:
			value, n = binary.Uvarint(b)
			if n <= 0 {
				return fmt.Errorf("invalid protobuf integer")
			}
			b = b[n:]
		case 2:
			length, n := binary.Uvarint(b)
			if n <= 0 || length > uint64(len(b)-n) {
				return fmt.Errorf("invalid protobuf length")
			}
			b = b[n:]
			data = b[:int(length)]
			b = b[int(length):]
		case 1:
			if len(b) < 8 {
				return io.ErrUnexpectedEOF
			}
			b = b[8:]
		case 5:
			if len(b) < 4 {
				return io.ErrUnexpectedEOF
			}
			b = b[4:]
		default:
			return fmt.Errorf("unsupported protobuf wire type %d", wire)
		}
		if err := visit(field, wire, data, value); err != nil {
			return err
		}
	}
	return nil
}
