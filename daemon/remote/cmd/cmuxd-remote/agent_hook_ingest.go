package main

// Hook ingest listener: while at least one agent conversation subscription is
// open, the daemon accepts newline-JSON agentconv.HookFrame lines on a
// per-user unix socket and routes each frame to the open subscriptions for
// the same (provider, session_id). Frames for sessions with no subscription
// are dropped (logged once per session). The socket exists only while
// subscriptions do; agent hooks write to it via `cmuxd-remote
// agent-hook-emit`, which never fails the hook (see agent_hook_emit.go).
//
// The registry is process-global because one process can host several RPC
// connections (ws mode) but the ingest socket path is per-user.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"github.com/manaflow-ai/cmux/daemon/remote/agentconv"
)

// dirOwnedByCurrentUser reports whether the stat'd entry belongs to this uid;
// anything unknowable counts as not owned (fail closed).
func dirOwnedByCurrentUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	return int(stat.Uid) == os.Getuid()
}

// agentHookSocketEnv overrides the ingest socket path (tests and tagged dev
// builds that must not collide with the user's stable daemon).
const agentHookSocketEnv = "CMUX_AGENT_HOOK_SOCKET"

const maxHookFrameBytes = 1024 * 1024

// defaultAgentHookSocketPath is the documented convention:
// /tmp/cmuxd-agentconv-<uid>/ingest.sock under a 0700 directory.
func defaultAgentHookSocketPath() string {
	if override := strings.TrimSpace(os.Getenv(agentHookSocketEnv)); override != "" {
		return override
	}
	return filepath.Join("/tmp", fmt.Sprintf("cmuxd-agentconv-%d", os.Getuid()), "ingest.sock")
}

type hookIngestRegistry struct {
	mu sync.Mutex
	// bySession routes frames: key is provider+"\n"+sessionID, value the set
	// of open subscriptions mirroring that session.
	bySession map[string]map[*agentconv.Subscription]struct{}
	// refs counts registered subscriptions; the listener lives while refs > 0.
	refs          int
	listener      net.Listener
	socketPath    string
	loggedUnknown map[string]bool
	logf          func(format string, args ...any)
}

var agentHookIngest = &hookIngestRegistry{
	bySession:     map[string]map[*agentconv.Subscription]struct{}{},
	loggedUnknown: map[string]bool{},
	logf: func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
	},
}

func hookSessionKey(provider agentconv.ProviderID, sessionID string) string {
	return string(provider) + "\n" + sessionID
}

// register indexes an open subscription and starts the listener if it is the
// first one. Subscriptions whose session id is unknown cannot be routed to
// and are not counted.
func (r *hookIngestRegistry) register(provider agentconv.ProviderID, sessionID string, subscription *agentconv.Subscription) {
	if sessionID == "" || subscription == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	key := hookSessionKey(provider, sessionID)
	set := r.bySession[key]
	if set == nil {
		set = map[*agentconv.Subscription]struct{}{}
		r.bySession[key] = set
	}
	if _, exists := set[subscription]; exists {
		return
	}
	set[subscription] = struct{}{}
	r.refs++
	if r.refs == 1 {
		r.startListenerLocked()
	}
}

func (r *hookIngestRegistry) unregister(provider agentconv.ProviderID, sessionID string, subscription *agentconv.Subscription) {
	if sessionID == "" || subscription == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	key := hookSessionKey(provider, sessionID)
	set := r.bySession[key]
	if set == nil {
		return
	}
	if _, exists := set[subscription]; !exists {
		return
	}
	delete(set, subscription)
	if len(set) == 0 {
		delete(r.bySession, key)
	}
	r.refs--
	if r.refs == 0 {
		r.stopListenerLocked()
	}
}

func (r *hookIngestRegistry) startListenerLocked() {
	socketPath := defaultAgentHookSocketPath()
	dir := filepath.Dir(socketPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		r.logf("cmuxd-remote: agent hook ingest disabled: %v", err)
		return
	}
	// The parent lives at a well-known name in /tmp, so a pre-created entry
	// could be someone else's directory or a symlink redirecting the socket
	// elsewhere. Require a real directory owned by this uid before using it.
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() {
		r.logf("cmuxd-remote: agent hook ingest disabled: %s is not a directory (symlink or replaced)", dir)
		return
	}
	if !dirOwnedByCurrentUser(info) {
		r.logf("cmuxd-remote: agent hook ingest disabled: %s is not owned by this user", dir)
		return
	}
	// MkdirAll keeps existing permissions; enforce 0700 on the parent.
	if err := os.Chmod(dir, 0o700); err != nil {
		r.logf("cmuxd-remote: agent hook ingest disabled: %v", err)
		return
	}
	// A live socket from another daemon must not be stolen; a stale file from
	// a dead one must be cleared.
	if _, err := os.Stat(socketPath); err == nil {
		if probe, dialErr := net.Dial("unix", socketPath); dialErr == nil {
			probe.Close()
			r.logf("cmuxd-remote: agent hook ingest socket %s is owned by another daemon; hook events will not reach this process", socketPath)
			return
		}
		_ = os.Remove(socketPath)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		r.logf("cmuxd-remote: agent hook ingest listen failed: %v", err)
		return
	}
	_ = os.Chmod(socketPath, 0o600)
	r.listener = listener
	r.socketPath = socketPath
	go r.acceptLoop(listener)
}

func (r *hookIngestRegistry) stopListenerLocked() {
	if r.listener != nil {
		_ = r.listener.Close()
		r.listener = nil
	}
	if r.socketPath != "" {
		_ = os.Remove(r.socketPath)
		r.socketPath = ""
	}
	r.loggedUnknown = map[string]bool{}
}

func (r *hookIngestRegistry) acceptLoop(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			// Listener closed (last subscription gone) or fatal: stop.
			return
		}
		go r.readFrames(conn)
	}
}

func (r *hookIngestRegistry) readFrames(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64*1024), maxHookFrameBytes)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var frame agentconv.HookFrame
		if err := json.Unmarshal(line, &frame); err != nil {
			continue
		}
		r.route(frame)
	}
}

func (r *hookIngestRegistry) route(frame agentconv.HookFrame) {
	if frame.SessionID == "" {
		return
	}
	key := hookSessionKey(frame.Provider, frame.SessionID)
	r.mu.Lock()
	set := r.bySession[key]
	if len(set) == 0 {
		if !r.loggedUnknown[key] {
			r.loggedUnknown[key] = true
			r.logf("cmuxd-remote: dropping hook frames for %s session %s (no open subscription)", frame.Provider, frame.SessionID)
		}
		r.mu.Unlock()
		return
	}
	subscriptions := make([]*agentconv.Subscription, 0, len(set))
	for subscription := range set {
		subscriptions = append(subscriptions, subscription)
	}
	r.mu.Unlock()
	for _, subscription := range subscriptions {
		subscription.InjectHookFrame(frame)
	}
}
