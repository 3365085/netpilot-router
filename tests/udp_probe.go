// STUN Binding probe for real UDP round trips (RFC 8489).
// Cross-compile: CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o udp-probe tests/udp_probe.go
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	addr := "stun.cloudflare.com:3478"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	started := time.Now()
	result := map[string]any{"endpoint": addr, "ok": false}
	err := func() error {
		c, err := net.DialTimeout("udp4", addr, 5*time.Second)
		if err != nil {
			return err
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(6 * time.Second))
		req := make([]byte, 20)
		binary.BigEndian.PutUint16(req, 1)
		binary.BigEndian.PutUint32(req[4:], 0x2112a442)
		if _, err = rand.Read(req[8:]); err != nil {
			return err
		}
		if _, err = c.Write(req); err != nil {
			return err
		}
		buf := make([]byte, 2048)
		n, err := c.Read(buf)
		if err != nil {
			return err
		}
		if n < 20 || binary.BigEndian.Uint16(buf) != 0x0101 || !bytes.Equal(buf[4:20], req[4:20]) {
			return fmt.Errorf("invalid STUN binding response")
		}
		for off := 20; off+4 <= n; {
			typ := binary.BigEndian.Uint16(buf[off:])
			size := int(binary.BigEndian.Uint16(buf[off+2:]))
			off += 4
			if off+size > n {
				return fmt.Errorf("truncated STUN attribute")
			}
			if typ == 0x20 && size >= 8 && buf[off+1] == 1 {
				ip := make(net.IP, 4)
				for i := 0; i < 4; i++ {
					ip[i] = buf[off+4+i] ^ req[4+i]
				}
				result["mapped_ip"] = ip.String()
				result["mapped_port"] = binary.BigEndian.Uint16(buf[off+2:]) ^ 0x2112
			}
			off += (size + 3) &^ 3
		}
		result["ok"] = true
		result["bytes"] = n
		return nil
	}()
	if err != nil {
		result["error"] = err.Error()
	}
	result["duration_ms"] = time.Since(started).Milliseconds()
	json.NewEncoder(os.Stdout).Encode(result)
	if err != nil {
		os.Exit(1)
	}
}
