package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net"
	"strings"
	"sync"
)

const (
	persistentDaemonBridgeLeaseParam = "bridge_lease_id"
	persistentDaemonBridgeLeaseMax   = 128
)

func newPersistentDaemonBridgeLeaseID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// persistentDaemonBridgeLeaseRegistry tracks every accepted stdio connection
// and the one connection that most recently claimed the slot. A new claimed
// bridge is authoritative: it closes all older connections, which makes
// takeover work even when an older binary did not send a lease id.
type persistentDaemonBridgeLeaseRegistry struct {
	mu          sync.Mutex
	connections map[net.Conn]struct{}
	holder      net.Conn
}

func newPersistentDaemonBridgeLeaseRegistry() *persistentDaemonBridgeLeaseRegistry {
	return &persistentDaemonBridgeLeaseRegistry{
		connections: make(map[net.Conn]struct{}),
	}
}

func (r *persistentDaemonBridgeLeaseRegistry) register(conn net.Conn) {
	if r == nil || conn == nil {
		return
	}
	r.mu.Lock()
	if r.connections == nil {
		r.connections = make(map[net.Conn]struct{})
	}
	r.connections[conn] = struct{}{}
	r.mu.Unlock()
}

func (r *persistentDaemonBridgeLeaseRegistry) claim(conn net.Conn, leaseID string) (int, error) {
	if r == nil || conn == nil {
		return 0, errors.New("persistent daemon bridge lease registry is unavailable")
	}
	leaseID = strings.TrimSpace(leaseID)
	if leaseID == "" {
		return 0, errors.New("persistent daemon bridge lease id is required")
	}
	if len(leaseID) > persistentDaemonBridgeLeaseMax {
		return 0, errors.New("persistent daemon bridge lease id is too long")
	}

	r.mu.Lock()
	if r.connections == nil {
		r.connections = make(map[net.Conn]struct{})
	}
	r.connections[conn] = struct{}{}
	evicted := make([]net.Conn, 0, len(r.connections)-1)
	for candidate := range r.connections {
		if candidate == conn {
			continue
		}
		evicted = append(evicted, candidate)
		delete(r.connections, candidate)
	}
	r.holder = conn
	r.mu.Unlock()

	for _, candidate := range evicted {
		_ = candidate.Close()
	}
	return len(evicted), nil
}

func (r *persistentDaemonBridgeLeaseRegistry) release(conn net.Conn) {
	if r == nil || conn == nil {
		return
	}
	r.mu.Lock()
	delete(r.connections, conn)
	if r.holder == conn {
		r.holder = nil
	}
	r.mu.Unlock()
}
