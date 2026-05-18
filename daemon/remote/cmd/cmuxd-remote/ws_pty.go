package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
	"nhooyr.io/websocket"
)

type wsPTYServerConfig struct {
	ListenAddr       string
	PTYAuthLeaseFile string
	RPCAuthLeaseFile string
	Shell            string
}

type wsLease struct {
	Version       int    `json:"version"`
	TokenSHA256   string `json:"token_sha256"`
	ExpiresAtUnix int64  `json:"expires_at_unix"`
	SessionID     string `json:"session_id,omitempty"`
	SingleUse     bool   `json:"single_use"`
}

type wsAuthFrame struct {
	Type         string `json:"type"`
	Token        string `json:"token"`
	SessionID    string `json:"session_id,omitempty"`
	AttachmentID string `json:"attachment_id,omitempty"`
	Cols         int    `json:"cols,omitempty"`
	Rows         int    `json:"rows,omitempty"`
}

type wsPTYControlFrame struct {
	Type string `json:"type"`
	Cols int    `json:"cols,omitempty"`
	Rows int    `json:"rows,omitempty"`
}

type wsPTYEventFrame struct {
	Type      string `json:"type"`
	SessionID string `json:"session_id,omitempty"`
	Message   string `json:"message,omitempty"`
}

type wsPTYLease = wsLease
type wsPTYAuthFrame = wsAuthFrame

var (
	errWSLeaseMissing   = errors.New("attach lease missing")
	errWSLeaseExpired   = errors.New("attach lease expired")
	errWSLeaseForbidden = errors.New("attach lease rejected")
	wsLeaseMu           sync.Mutex
)

func runWebSocketPTYServer(ctx context.Context, cfg wsPTYServerConfig, stderr io.Writer) error {
	addr := cfg.ListenAddr
	if strings.TrimSpace(addr) == "" {
		addr = "127.0.0.1:7777"
	}
	if strings.TrimSpace(cfg.PTYAuthLeaseFile) == "" {
		return errors.New("auth lease file is required")
	}

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	defer listener.Close()

	server := &http.Server{
		Handler:           newWebSocketPTYHandler(cfg, stderr),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	_, _ = fmt.Fprintf(stderr, "cmuxd-remote ws listening on %s\n", listener.Addr().String())
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func newWebSocketPTYHandler(cfg wsPTYServerConfig, stderr io.Writer) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, statErr := os.Stat(cfg.PTYAuthLeaseFile)
		locked := statErr != nil
		w.Header().Set("content-type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok":     true,
			"locked": locked,
		})
	})
	mux.HandleFunc("/terminal", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocketPTY(w, r, cfg, stderr)
	})
	mux.HandleFunc("/rpc", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocketRPC(w, r, cfg)
	})
	return mux
}

func handleWebSocketPTY(w http.ResponseWriter, r *http.Request, cfg wsPTYServerConfig, stderr io.Writer) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	defer conn.Close(websocket.StatusInternalError, "closed")
	conn.SetReadLimit(1 << 20)

	authCtx, cancelAuth := context.WithTimeout(r.Context(), 5*time.Second)
	msgType, payload, err := conn.Read(authCtx)
	cancelAuth()
	if err != nil {
		_ = conn.Close(websocket.StatusPolicyViolation, "auth required")
		return
	}
	if msgType != websocket.MessageText {
		_ = conn.Close(websocket.StatusUnsupportedData, "auth must be text JSON")
		return
	}

	var auth wsAuthFrame
	if err := json.Unmarshal(payload, &auth); err != nil || auth.Type != "auth" || auth.Token == "" {
		_ = conn.Close(websocket.StatusPolicyViolation, "invalid auth")
		return
	}
	if auth.Cols <= 0 {
		auth.Cols = 80
	}
	if auth.Rows <= 0 {
		auth.Rows = 24
	}
	if auth.SessionID == "" {
		auth.SessionID = "default"
	}

	if err := consumeWebSocketLease(cfg.PTYAuthLeaseFile, auth); err != nil {
		if errors.Is(err, errWSLeaseMissing) {
			_ = conn.Close(websocket.StatusPolicyViolation, "no active lease")
			return
		}
		if errors.Is(err, errWSLeaseExpired) {
			_ = conn.Close(websocket.StatusPolicyViolation, "lease expired")
			return
		}
		_ = conn.Close(websocket.StatusPolicyViolation, "lease rejected")
		return
	}

	shellPath := resolvePTYShell(cfg.Shell)
	cmd := exec.Command(shellPath)
	cmd.Env = defaultWebSocketPTYEnv(shellPath)
	ptyFile, err := pty.StartWithSize(cmd, &pty.Winsize{
		Cols: uint16(auth.Cols),
		Rows: uint16(auth.Rows),
	})
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ws pty start failed: %v\n", err)
		_ = conn.Close(websocket.StatusInternalError, "pty start failed")
		return
	}
	defer func() {
		_ = ptyFile.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	writeMu := &sync.Mutex{}
	if err := writeWSJSON(r.Context(), conn, writeMu, wsPTYEventFrame{
		Type:      "ready",
		SessionID: auth.SessionID,
	}); err != nil {
		return
	}

	sessionCtx, cancelSession := context.WithCancel(r.Context())
	defer cancelSession()
	done := make(chan struct{})
	go pumpPTYToWebSocket(sessionCtx, cancelSession, conn, writeMu, ptyFile, done)
	pumpWebSocketToPTY(sessionCtx, conn, ptyFile, done)
	_ = conn.Close(websocket.StatusNormalClosure, "closed")
}

func consumeWebSocketLease(path string, auth wsAuthFrame) error {
	wsLeaseMu.Lock()
	defer wsLeaseMu.Unlock()

	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return errWSLeaseMissing
		}
		return err
	}
	var lease wsLease
	if err := json.Unmarshal(data, &lease); err != nil {
		return errWSLeaseForbidden
	}
	if lease.Version != 1 {
		return errWSLeaseForbidden
	}
	if lease.ExpiresAtUnix <= time.Now().Unix() {
		return errWSLeaseExpired
	}
	if lease.SessionID != "" && lease.SessionID != auth.SessionID {
		return errWSLeaseForbidden
	}

	expected, err := hex.DecodeString(strings.TrimSpace(lease.TokenSHA256))
	if err != nil || len(expected) != sha256.Size {
		return errWSLeaseForbidden
	}
	actualHash := sha256.Sum256([]byte(auth.Token))
	if subtle.ConstantTimeCompare(expected, actualHash[:]) != 1 {
		return errWSLeaseForbidden
	}

	if lease.SingleUse {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

type wsRPCFrameWriter struct {
	conn    *websocket.Conn
	writeMu *sync.Mutex
	ctx     context.Context
}

func (w *wsRPCFrameWriter) writeResponse(resp rpcResponse) error {
	return w.writeJSONFrame(resp)
}

func (w *wsRPCFrameWriter) writeEvent(event rpcEvent) error {
	return w.writeJSONFrame(event)
}

func (w *wsRPCFrameWriter) writeJSONFrame(payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.conn.Write(w.ctx, websocket.MessageText, data)
}

func handleWebSocketRPC(w http.ResponseWriter, r *http.Request, cfg wsPTYServerConfig) {
	if strings.TrimSpace(cfg.RPCAuthLeaseFile) == "" {
		http.NotFound(w, r)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	defer conn.Close(websocket.StatusInternalError, "closed")
	conn.SetReadLimit(maxRPCFrameBytes)

	authCtx, cancelAuth := context.WithTimeout(r.Context(), 5*time.Second)
	msgType, payload, err := conn.Read(authCtx)
	cancelAuth()
	if err != nil {
		_ = conn.Close(websocket.StatusPolicyViolation, "auth required")
		return
	}
	if msgType != websocket.MessageText {
		_ = conn.Close(websocket.StatusUnsupportedData, "auth must be text JSON")
		return
	}

	var auth wsAuthFrame
	if err := json.Unmarshal(payload, &auth); err != nil || auth.Type != "auth" || auth.Token == "" {
		_ = conn.Close(websocket.StatusPolicyViolation, "invalid auth")
		return
	}
	if auth.SessionID == "" {
		auth.SessionID = "default"
	}

	if err := consumeWebSocketLease(cfg.RPCAuthLeaseFile, auth); err != nil {
		if errors.Is(err, errWSLeaseMissing) {
			_ = conn.Close(websocket.StatusPolicyViolation, "no active lease")
			return
		}
		if errors.Is(err, errWSLeaseExpired) {
			_ = conn.Close(websocket.StatusPolicyViolation, "lease expired")
			return
		}
		_ = conn.Close(websocket.StatusPolicyViolation, "lease rejected")
		return
	}

	writeMu := &sync.Mutex{}
	if err := writeWSJSON(r.Context(), conn, writeMu, wsPTYEventFrame{
		Type:      "ready",
		SessionID: auth.SessionID,
	}); err != nil {
		return
	}

	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		frameWriter: &wsRPCFrameWriter{
			conn:    conn,
			writeMu: writeMu,
			ctx:     r.Context(),
		},
	}
	defer server.closeAll()

	for {
		msgType, payload, err := conn.Read(r.Context())
		if err != nil {
			_ = conn.Close(websocket.StatusNormalClosure, "closed")
			return
		}
		if msgType != websocket.MessageText {
			_ = conn.Close(websocket.StatusUnsupportedData, "rpc frames must be text JSON")
			return
		}

		payload = bytes.TrimSpace(payload)
		if len(payload) == 0 {
			continue
		}

		var req rpcRequest
		if err := json.Unmarshal(payload, &req); err != nil {
			if err := server.frameWriter.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "invalid JSON request",
				},
			}); err != nil {
				_ = conn.Close(websocket.StatusInternalError, "write failed")
				return
			}
			continue
		}

		resp := server.handleRequest(req)
		if err := server.frameWriter.writeResponse(resp); err != nil {
			_ = conn.Close(websocket.StatusInternalError, "write failed")
			return
		}
	}
}

func defaultWebSocketPTYEnv(shellPath string) []string {
	env, order := envMapWithOrder(os.Environ())
	set := func(key, value string) {
		if _, ok := env[key]; !ok {
			order = append(order, key)
		}
		env[key] = value
	}
	setIfMissing := func(key, value string) {
		if strings.TrimSpace(env[key]) == "" {
			set(key, value)
		}
	}

	set("TERM", "xterm-256color")
	setIfMissing("COLORTERM", "truecolor")
	setIfMissing("TERM_PROGRAM", "ghostty")
	setIfMissing("SHELL", shellPath)
	set("CMUX_REMOTE_TRANSPORT", "ws")
	if !envHasUTF8Locale(env) {
		set("LANG", "C.UTF-8")
		set("LC_CTYPE", "C.UTF-8")
		set("LC_ALL", "C.UTF-8")
	}

	out := make([]string, 0, len(order))
	seen := make(map[string]struct{}, len(order))
	for _, key := range order {
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, key+"="+env[key])
	}
	return out
}

func envMapWithOrder(values []string) (map[string]string, []string) {
	env := make(map[string]string, len(values))
	order := make([]string, 0, len(values))
	for _, value := range values {
		key, rest, ok := strings.Cut(value, "=")
		if !ok {
			continue
		}
		if _, exists := env[key]; !exists {
			order = append(order, key)
		}
		env[key] = rest
	}
	return env, order
}

func envHasUTF8Locale(env map[string]string) bool {
	for _, key := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		value := strings.ToUpper(strings.TrimSpace(env[key]))
		if value == "" {
			continue
		}
		return strings.Contains(value, "UTF-8") || strings.Contains(value, "UTF8")
	}
	return false
}

func writeWSJSON(ctx context.Context, conn *websocket.Conn, writeMu *sync.Mutex, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	writeMu.Lock()
	defer writeMu.Unlock()
	return conn.Write(ctx, websocket.MessageText, data)
}

func pumpPTYToWebSocket(ctx context.Context, cancel context.CancelFunc, conn *websocket.Conn, writeMu *sync.Mutex, ptyFile *os.File, done chan<- struct{}) {
	defer close(done)
	defer func() {
		writeMu.Lock()
		_ = conn.Close(websocket.StatusNormalClosure, "pty closed")
		writeMu.Unlock()
		cancel()
	}()
	buffer := make([]byte, 32768)
	for {
		n, err := ptyFile.Read(buffer)
		if n > 0 {
			chunk := append([]byte(nil), buffer[:n]...)
			writeMu.Lock()
			writeErr := conn.Write(ctx, websocket.MessageBinary, chunk)
			writeMu.Unlock()
			if writeErr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func pumpWebSocketToPTY(ctx context.Context, conn *websocket.Conn, ptyFile *os.File, done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		default:
		}

		msgType, payload, err := conn.Read(ctx)
		if err != nil {
			return
		}
		switch msgType {
		case websocket.MessageBinary:
			_, _ = ptyFile.Write(payload)
		case websocket.MessageText:
			var control wsPTYControlFrame
			if err := json.Unmarshal(payload, &control); err != nil {
				continue
			}
			switch control.Type {
			case "resize":
				if control.Cols > 0 && control.Rows > 0 {
					_ = pty.Setsize(ptyFile, &pty.Winsize{
						Cols: uint16(control.Cols),
						Rows: uint16(control.Rows),
					})
				}
			case "close":
				return
			}
		}
	}
}

func resolvePTYShell(explicit string) string {
	if strings.TrimSpace(explicit) != "" {
		return explicit
	}
	if shell := strings.TrimSpace(os.Getenv("SHELL")); shell != "" {
		if _, err := os.Stat(shell); err == nil {
			return shell
		}
	}
	for _, candidate := range []string{"/bin/bash", "/usr/bin/bash", "/bin/sh"} {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return filepath.Clean("/bin/sh")
}
