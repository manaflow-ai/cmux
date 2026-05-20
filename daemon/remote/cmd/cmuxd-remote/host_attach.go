package main

// host_attach.go implements RPC methods for attaching to surfaces on the host
// machine's local cmux instance. This enables `cmux attach <host>` — a local
// cmux surface whose PTY I/O is transparently bridged to an existing surface
// on the remote cmux via cmuxd-remote.
//
// Architecture:
//
//   Local cmux ──SSH──▶ cmuxd-remote ──Unix socket──▶ Host cmux
//                           │                             │
//   local surface ◀─ base64 I/O relay ─▶ host surface PTY
//
// The host cmux socket is auto-discovered from the standard path
// ~/Library/Application Support/cmux/cmux.sock or overridden via
// CMUX_HOST_SOCKET_PATH. The socket must be in "automation" or
// "allowAll" mode for external processes to connect.

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// hostAttachState tracks an active attach session bridging a local cmux
// surface to a host cmux surface.
type hostAttachState struct {
	mu         sync.Mutex
	surfaceRef string          // e.g. "surface:4"
	stopCh     chan struct{}    // signals the output pump to stop
	stopped    bool
}

// discoverHostSocketPath returns the path to the host machine's cmux Unix socket.
func discoverHostSocketPath() string {
	if envPath := os.Getenv("CMUX_HOST_SOCKET_PATH"); envPath != "" {
		return envPath
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "cmux", "cmux.sock")
}

// dialHostCmux connects to the host cmux's Unix socket.
func dialHostCmux() (net.Conn, error) {
	socketPath := discoverHostSocketPath()
	if socketPath == "" {
		return nil, fmt.Errorf("cannot determine host cmux socket path")
	}
	conn, err := net.DialTimeout("unix", socketPath, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to host cmux at %s: %w", socketPath, err)
	}
	return conn, nil
}

// hostCmuxRoundTrip sends a V2 JSON-RPC request to the host cmux socket
// and returns the parsed response.
func hostCmuxRoundTrip(method string, params map[string]any) (map[string]any, error) {
	conn, err := dialHostCmux()
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	id := randomHex(8)
	req := map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	}
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var resp map[string]any
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		return nil, fmt.Errorf("invalid response JSON: %w", err)
	}

	if ok, _ := resp["ok"].(bool); !ok {
		if errObj, _ := resp["error"].(map[string]any); errObj != nil {
			code, _ := errObj["code"].(string)
			msg, _ := errObj["message"].(string)
			return nil, fmt.Errorf("host cmux error [%s]: %s", code, msg)
		}
		return nil, fmt.Errorf("host cmux returned error")
	}

	result, _ := resp["result"].(map[string]any)
	return result, nil
}

// handleHostSurfaceList lists surfaces on the host cmux by calling surface.list
// and tree via the host socket.
func (s *rpcServer) handleHostSurfaceList(req rpcRequest) rpcResponse {
	// Try tree --all equivalent: workspace.tree
	params := map[string]any{"all": true}
	if wsID, ok := getStringParam(req.Params, "workspace_id"); ok {
		params["workspace_id"] = wsID
	}

	result, err := hostCmuxRoundTrip("workspace.tree", params)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "host_error",
				Message: err.Error(),
			},
		}
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: result,
	}
}

// handleHostSurfaceReadScreen reads the screen content of a host cmux surface.
func (s *rpcServer) handleHostSurfaceReadScreen(req rpcRequest) rpcResponse {
	surfaceID, ok := getStringParam(req.Params, "surface_id")
	if !ok || surfaceID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.surface.read_screen requires surface_id",
			},
		}
	}

	params := map[string]any{"surface_id": surfaceID}
	if scrollback, ok := req.Params["scrollback"]; ok {
		params["scrollback"] = scrollback
	}
	if lines, ok := getIntParam(req.Params, "lines"); ok {
		params["lines"] = lines
	}

	result, err := hostCmuxRoundTrip("surface.read_screen", params)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "host_error",
				Message: err.Error(),
			},
		}
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: result,
	}
}

// handleHostSurfaceSendText sends text input to a host cmux surface.
func (s *rpcServer) handleHostSurfaceSendText(req rpcRequest) rpcResponse {
	surfaceID, ok := getStringParam(req.Params, "surface_id")
	if !ok || surfaceID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.surface.send_text requires surface_id",
			},
		}
	}

	text, ok := getStringParam(req.Params, "text")
	if !ok {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.surface.send_text requires text",
			},
		}
	}

	result, err := hostCmuxRoundTrip("surface.send_text", map[string]any{
		"surface_id": surfaceID,
		"text":       text,
	})
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "host_error",
				Message: err.Error(),
			},
		}
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: result,
	}
}

// handleHostSurfaceSendKey sends a key event to a host cmux surface.
func (s *rpcServer) handleHostSurfaceSendKey(req rpcRequest) rpcResponse {
	surfaceID, ok := getStringParam(req.Params, "surface_id")
	if !ok || surfaceID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.surface.send_key requires surface_id",
			},
		}
	}

	key, ok := getStringParam(req.Params, "key")
	if !ok {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.surface.send_key requires key",
			},
		}
	}

	result, err := hostCmuxRoundTrip("surface.send_key", map[string]any{
		"surface_id": surfaceID,
		"key":        key,
	})
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "host_error",
				Message: err.Error(),
			},
		}
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: result,
	}
}

// handleHostAttach starts a streaming attach session to a host cmux surface.
// It connects to the host cmux socket, subscribes to the surface's PTY output,
// and pumps data back to the local cmux as base64-encoded stream events.
//
// The caller can write to the surface via host.surface.send_text and
// host.surface.send_key while the attach stream is active.
func (s *rpcServer) handleHostAttach(req rpcRequest) rpcResponse {
	surfaceID, ok := getStringParam(req.Params, "surface_id")
	if !ok || surfaceID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.attach requires surface_id",
			},
		}
	}

	// Verify surface exists by reading its screen
	_, err := hostCmuxRoundTrip("surface.read_screen", map[string]any{
		"surface_id": surfaceID,
	})
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "host_error",
				Message: fmt.Sprintf("cannot access host surface %s: %v", surfaceID, err),
			},
		}
	}

	s.mu.Lock()
	attachID := fmt.Sprintf("attach-%d", s.nextStreamID)
	s.nextStreamID++

	state := &hostAttachState{
		surfaceRef: surfaceID,
		stopCh:     make(chan struct{}),
	}
	s.hostAttachments[attachID] = state
	s.mu.Unlock()

	// Start output polling pump in background
	go s.hostAttachPump(attachID, state)

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"attach_id":  attachID,
			"surface_id": surfaceID,
			"status":     "attached",
		},
	}
}

// handleHostDetach stops an active host attach session.
func (s *rpcServer) handleHostDetach(req rpcRequest) rpcResponse {
	attachID, ok := getStringParam(req.Params, "attach_id")
	if !ok || attachID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "host.detach requires attach_id",
			},
		}
	}

	s.mu.Lock()
	state, exists := s.hostAttachments[attachID]
	if exists {
		delete(s.hostAttachments, attachID)
	}
	s.mu.Unlock()

	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "attach session not found",
			},
		}
	}

	state.mu.Lock()
	if !state.stopped {
		state.stopped = true
		close(state.stopCh)
	}
	state.mu.Unlock()

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"attach_id": attachID,
			"detached":  true,
		},
	}
}

// hostAttachPump polls the host surface's screen and emits stream events
// with the screen content. This provides a near-real-time view of the
// remote surface.
//
// Future optimization: if cmux adds a streaming/subscribe API for surface
// output, this can be replaced with a true event-driven pump instead of polling.
func (s *rpcServer) hostAttachPump(attachID string, state *hostAttachState) {
	defer func() {
		s.mu.Lock()
		delete(s.hostAttachments, attachID)
		s.mu.Unlock()
	}()

	var lastScreen string
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-state.stopCh:
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "host.attach.eof",
				StreamID: attachID,
			})
			return
		case <-ticker.C:
			result, err := hostCmuxRoundTrip("surface.read_screen", map[string]any{
				"surface_id": state.surfaceRef,
			})
			if err != nil {
				_ = s.frameWriter.writeEvent(rpcEvent{
					Event:    "host.attach.error",
					StreamID: attachID,
					Error:    err.Error(),
				})
				return
			}

			// Extract screen text from result
			screen := extractScreenText(result)
			if screen != lastScreen {
				lastScreen = screen
				_ = s.frameWriter.writeEvent(rpcEvent{
					Event:      "host.attach.data",
					StreamID:   attachID,
					DataBase64: base64.StdEncoding.EncodeToString([]byte(screen)),
				})
			}
		}
	}
}

// extractScreenText pulls the screen content string from a read_screen result.
// It checks well-known keys in a deterministic order.
func extractScreenText(result map[string]any) string {
	if result == nil {
		return ""
	}
	// Check well-known keys in priority order
	for _, key := range []string{"text", "content", "screen", "data", "output"} {
		if text, ok := result[key].(string); ok {
			return text
		}
	}
	return ""
}

