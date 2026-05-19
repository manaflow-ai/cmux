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
	"syscall"
	"time"

	"github.com/creack/pty"
	"nhooyr.io/websocket"
)

type wsPTYServerConfig struct {
	ListenAddr       string
	PTYAuthLeaseFile string
	RPCAuthLeaseFile string
	Shell            string
	PTYHub           *wsPTYHub
	ScrollbackLimit  int
	SessionIdleTTL   time.Duration
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
	Type         string `json:"type"`
	SessionID    string `json:"session_id,omitempty"`
	AttachmentID string `json:"attachment_id,omitempty"`
	Message      string `json:"message,omitempty"`
}

type wsPTYLease = wsLease
type wsPTYAuthFrame = wsAuthFrame

var (
	errWSLeaseMissing   = errors.New("attach lease missing")
	errWSLeaseExpired   = errors.New("attach lease expired")
	errWSLeaseForbidden = errors.New("attach lease rejected")
	wsLeaseMu           sync.Mutex
)

const (
	defaultPTYCols                 = 80
	defaultPTYRows                 = 24
	maxPTYDimension                = 65535
	defaultWebSocketScrollbackCap  = 1 << 20
	defaultWebSocketWriteQueueCap  = 256
	defaultWebSocketWriteTimeout   = 10 * time.Second
	defaultWebSocketSessionIdleTTL = 5 * time.Minute
)

type wsPTYOutgoingFrame struct {
	messageType websocket.MessageType
	payload     []byte
}

type wsPTYAttachment struct {
	sessionID string
	id        string
	cols      int
	rows      int
	send      chan wsPTYOutgoingFrame
	cancel    context.CancelFunc
	conn      *websocket.Conn
}

type wsPTYSession struct {
	id             string
	cmd            *exec.Cmd
	ptyFile        *os.File
	ttyFile        *os.File
	attachments    map[string]*wsPTYAttachment
	effectiveCols  int
	effectiveRows  int
	lastKnownCols  int
	lastKnownRows  int
	resizeConfirms int
	scrollback     []byte
	done           chan struct{}
	idleTimer      *time.Timer
	closed         bool
	ptyWriteMu     sync.Mutex
	closeTTYOnce   sync.Once
	closePTYOnce   sync.Once
}

type wsPTYHub struct {
	mu               sync.Mutex
	sessions         map[string]*wsPTYSession
	nextAttachmentID uint64
	shell            string
	stderr           io.Writer
	scrollbackLimit  int
	sessionIdleTTL   time.Duration
}

func newWebSocketPTYHub(cfg wsPTYServerConfig, stderr io.Writer) *wsPTYHub {
	limit := cfg.ScrollbackLimit
	if limit <= 0 {
		limit = defaultWebSocketScrollbackCap
	}
	idleTTL := cfg.SessionIdleTTL
	if idleTTL <= 0 {
		idleTTL = defaultWebSocketSessionIdleTTL
	}
	return &wsPTYHub{
		sessions:        map[string]*wsPTYSession{},
		shell:           strings.TrimSpace(cfg.Shell),
		stderr:          stderr,
		scrollbackLimit: limit,
		sessionIdleTTL:  idleTTL,
	}
}

func runWebSocketPTYServer(ctx context.Context, cfg wsPTYServerConfig, stderr io.Writer) error {
	addr := cfg.ListenAddr
	if strings.TrimSpace(addr) == "" {
		addr = "127.0.0.1:7777"
	}
	if strings.TrimSpace(cfg.PTYAuthLeaseFile) == "" {
		return errors.New("auth lease file is required")
	}
	if cfg.PTYHub == nil {
		cfg.PTYHub = newWebSocketPTYHub(cfg, stderr)
	}
	defer cfg.PTYHub.closeAll()

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
	if cfg.PTYHub == nil {
		cfg.PTYHub = newWebSocketPTYHub(cfg, stderr)
	}

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
	auth.Cols, auth.Rows = normalizePTYSize(auth.Cols, auth.Rows)
	if auth.SessionID == "" {
		auth.SessionID = "default"
	}
	auth.Cols, auth.Rows = normalizePTYSize(auth.Cols, auth.Rows)

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

	attachment, err := cfg.PTYHub.attach(r.Context(), conn, auth)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ws pty attach failed: %v\n", err)
		_ = conn.Close(websocket.StatusInternalError, "pty start failed")
		return
	}
	defer cfg.PTYHub.detach(attachment)

	pumpWebSocketToPTY(r.Context(), cfg.PTYHub, attachment, conn)
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

func (h *wsPTYHub) attach(ctx context.Context, conn *websocket.Conn, auth wsAuthFrame) (*wsPTYAttachment, error) {
	sessionID := strings.TrimSpace(auth.SessionID)
	if sessionID == "" {
		sessionID = "default"
	}
	cols, rows := normalizePTYSize(auth.Cols, auth.Rows)

	h.mu.Lock()

	session := h.sessions[sessionID]
	if session == nil || session.closed {
		var err error
		session, err = h.startSessionLocked(sessionID, cols, rows)
		if err != nil {
			h.mu.Unlock()
			return nil, err
		}
		h.sessions[sessionID] = session
	}

	attachmentID := strings.TrimSpace(auth.AttachmentID)
	if attachmentID == "" {
		attachmentID = fmt.Sprintf("att-%d", h.nextAttachmentID)
		h.nextAttachmentID++
	}
	var superseded *wsPTYAttachment
	if old := session.attachments[attachmentID]; old != nil {
		old.cancel()
		delete(session.attachments, attachmentID)
		superseded = old
	}

	attachmentCtx, cancel := context.WithCancel(ctx)
	attachment := &wsPTYAttachment{
		sessionID: sessionID,
		id:        attachmentID,
		cols:      cols,
		rows:      rows,
		send:      make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:    cancel,
		conn:      conn,
	}
	replay := append([]byte(nil), session.scrollback...)
	if ok := attachment.enqueueReady(sessionID); !ok {
		cancel()
		h.mu.Unlock()
		if superseded != nil {
			superseded.closeNow()
		}
		return nil, errors.New("failed to queue ready frame")
	}
	if len(replay) > 0 {
		if ok := attachment.enqueueBinary(replay); !ok {
			cancel()
			h.mu.Unlock()
			if superseded != nil {
				superseded.closeNow()
			}
			return nil, errors.New("failed to queue replay frame")
		}
	}
	session.attachments[attachmentID] = attachment
	shouldApplySize := h.recomputeSessionSizeLocked(session)
	sessionDone := session.done
	h.mu.Unlock()

	if superseded != nil {
		superseded.closeNow()
	}
	if shouldApplySize {
		h.applyCurrentPTYSize(session)
	}

	go attachment.writeLoop(attachmentCtx, conn, sessionDone)
	return attachment, nil
}

func (h *wsPTYHub) startSessionLocked(sessionID string, cols int, rows int) (*wsPTYSession, error) {
	shellPath := resolvePTYShell(h.shell)
	cmd := exec.Command(shellPath)
	cmd.Env = defaultWebSocketPTYEnv(shellPath)
	ptyFile, ttyFile, err := startPTYCommand(cmd, cols, rows)
	if err != nil {
		return nil, err
	}
	session := &wsPTYSession{
		id:            sessionID,
		cmd:           cmd,
		ptyFile:       ptyFile,
		ttyFile:       ttyFile,
		attachments:   map[string]*wsPTYAttachment{},
		effectiveCols: cols,
		effectiveRows: rows,
		lastKnownCols: cols,
		lastKnownRows: rows,
		done:          make(chan struct{}),
	}
	go h.waitSessionProcess(session)
	go h.pumpSession(session)
	return session, nil
}

func startPTYCommand(cmd *exec.Cmd, cols int, rows int) (*os.File, *os.File, error) {
	ptyFile, ttyFile, err := pty.Open()
	if err != nil {
		return nil, nil, err
	}
	closeFiles := true
	defer func() {
		if closeFiles {
			_ = ptyFile.Close()
			_ = ttyFile.Close()
		}
	}()

	if err := pty.Setsize(ttyFile, &pty.Winsize{
		Cols: uint16(cols),
		Rows: uint16(rows),
	}); err != nil {
		return nil, nil, err
	}
	if cmd.Stdout == nil {
		cmd.Stdout = ttyFile
	}
	if cmd.Stderr == nil {
		cmd.Stderr = ttyFile
	}
	if cmd.Stdin == nil {
		cmd.Stdin = ttyFile
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setsid = true
	cmd.SysProcAttr.Setctty = true

	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	closeFiles = false
	return ptyFile, ttyFile, nil
}

func (h *wsPTYHub) detach(attachment *wsPTYAttachment) bool {
	if attachment == nil {
		return false
	}
	h.mu.Lock()

	session := h.sessions[attachment.sessionID]
	if session == nil {
		h.mu.Unlock()
		return false
	}
	current := session.attachments[attachment.id]
	if current != attachment {
		h.mu.Unlock()
		return false
	}
	delete(session.attachments, attachment.id)
	attachment.cancel()
	shouldApplySize := h.recomputeSessionSizeLocked(session)
	h.mu.Unlock()

	if shouldApplySize {
		h.applyCurrentPTYSize(session)
	}
	return true
}

func (h *wsPTYHub) dropAttachment(attachment *wsPTYAttachment) {
	if attachment == nil {
		return
	}
	h.detach(attachment)
	attachment.closeNow()
}

func (h *wsPTYHub) closeAll() {
	h.mu.Lock()
	sessions := make([]*wsPTYSession, 0, len(h.sessions))
	for id, session := range h.sessions {
		delete(h.sessions, id)
		h.cancelIdleReapLocked(session)
		sessions = append(sessions, session)
	}
	h.mu.Unlock()

	for _, session := range sessions {
		if session.cmd != nil && session.cmd.Process != nil {
			_ = session.cmd.Process.Kill()
		}
		session.closePTYFiles()
	}
}

func (h *wsPTYHub) waitSessionProcess(session *wsPTYSession) {
	if session.cmd != nil {
		_ = session.cmd.Wait()
	}
	session.closeTTYFile()
}

func (session *wsPTYSession) closePTYFiles() {
	session.closeTTYFile()
	session.closePTYFile()
}

func (session *wsPTYSession) closeTTYFile() {
	session.closeTTYOnce.Do(func() {
		session.ptyWriteMu.Lock()
		defer session.ptyWriteMu.Unlock()
		if session.ttyFile != nil {
			_ = session.ttyFile.Close()
			session.ttyFile = nil
		}
	})
}

func (session *wsPTYSession) closePTYFile() {
	session.closePTYOnce.Do(func() {
		session.ptyWriteMu.Lock()
		defer session.ptyWriteMu.Unlock()
		_ = session.ptyFile.Close()
	})
}

func (h *wsPTYHub) activeSessionCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.sessions)
}

func (h *wsPTYHub) maxScrollbackBytes() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	maxBytes := 0
	for _, session := range h.sessions {
		if len(session.scrollback) > maxBytes {
			maxBytes = len(session.scrollback)
		}
	}
	return maxBytes
}

func (h *wsPTYHub) pumpSession(session *wsPTYSession) {
	defer h.finishSession(session)

	buffer := make([]byte, 32768)
	for {
		n, err := session.ptyFile.Read(buffer)
		if n > 0 {
			chunk := append([]byte(nil), buffer[:n]...)
			h.recordAndBroadcast(session, chunk)
			h.confirmPTYSizeAfterOutput(session)
		}
		if err != nil {
			return
		}
		if n == 0 {
			return
		}
	}
}

func (h *wsPTYHub) finishSession(session *wsPTYSession) {
	session.closePTYFiles()

	h.mu.Lock()
	if h.sessions[session.id] == session {
		delete(h.sessions, session.id)
	}
	h.cancelIdleReapLocked(session)
	session.closed = true
	for id := range session.attachments {
		delete(session.attachments, id)
	}
	close(session.done)
	h.mu.Unlock()
}

func (h *wsPTYHub) recordAndBroadcast(session *wsPTYSession, data []byte) {
	h.mu.Lock()
	if session.closed {
		h.mu.Unlock()
		return
	}
	h.appendScrollbackLocked(session, data)
	attachments := make([]*wsPTYAttachment, 0, len(session.attachments))
	for _, attachment := range session.attachments {
		attachments = append(attachments, attachment)
	}
	h.mu.Unlock()

	for _, attachment := range attachments {
		if ok := attachment.enqueueBinary(data); !ok {
			h.dropAttachment(attachment)
		}
	}
}

func (h *wsPTYHub) appendScrollbackLocked(session *wsPTYSession, data []byte) {
	limit := h.scrollbackLimit
	if limit <= 0 || len(data) == 0 {
		return
	}
	if len(data) >= limit {
		session.scrollback = append(make([]byte, 0, limit), data[len(data)-limit:]...)
		return
	}
	if len(session.scrollback)+len(data) > limit {
		keep := limit - len(data)
		if keep > len(session.scrollback) {
			keep = len(session.scrollback)
		}
		next := make([]byte, 0, limit)
		if keep > 0 {
			next = append(next, session.scrollback[len(session.scrollback)-keep:]...)
		}
		session.scrollback = append(next, data...)
		return
	}
	if cap(session.scrollback) > limit {
		next := make([]byte, len(session.scrollback), limit)
		copy(next, session.scrollback)
		session.scrollback = next
	}
	session.scrollback = append(session.scrollback, data...)
}

func (h *wsPTYHub) recomputeSessionSizeLocked(session *wsPTYSession) bool {
	if len(session.attachments) == 0 {
		session.effectiveCols = session.lastKnownCols
		session.effectiveRows = session.lastKnownRows
		h.scheduleIdleReapLocked(session)
		return false
	}
	h.cancelIdleReapLocked(session)

	minCols := 0
	minRows := 0
	for _, attachment := range session.attachments {
		if minCols == 0 || attachment.cols < minCols {
			minCols = attachment.cols
		}
		if minRows == 0 || attachment.rows < minRows {
			minRows = attachment.rows
		}
	}
	session.effectiveCols = minCols
	session.effectiveRows = minRows
	session.lastKnownCols = minCols
	session.lastKnownRows = minRows
	session.resizeConfirms = 4

	return true
}

func (h *wsPTYHub) scheduleIdleReapLocked(session *wsPTYSession) {
	if h.sessionIdleTTL <= 0 || session.closed || len(session.attachments) > 0 {
		return
	}
	h.cancelIdleReapLocked(session)
	session.idleTimer = time.AfterFunc(h.sessionIdleTTL, func() {
		h.reapIdleSession(session)
	})
}

func (h *wsPTYHub) cancelIdleReapLocked(session *wsPTYSession) {
	if session.idleTimer == nil {
		return
	}
	session.idleTimer.Stop()
	session.idleTimer = nil
}

func (h *wsPTYHub) reapIdleSession(session *wsPTYSession) {
	h.mu.Lock()
	if h.sessions[session.id] != session || session.closed || len(session.attachments) > 0 {
		h.mu.Unlock()
		return
	}
	delete(h.sessions, session.id)
	session.idleTimer = nil
	h.mu.Unlock()

	if session.cmd != nil && session.cmd.Process != nil {
		_ = session.cmd.Process.Kill()
	}
	session.closePTYFiles()
}

func (h *wsPTYHub) confirmPTYSizeAfterOutput(session *wsPTYSession) {
	h.mu.Lock()
	if h.sessions[session.id] != session || session.closed || session.resizeConfirms <= 0 {
		h.mu.Unlock()
		return
	}
	session.resizeConfirms--
	h.mu.Unlock()

	h.applyCurrentPTYSize(session)
}

func (h *wsPTYHub) applyCurrentPTYSize(session *wsPTYSession) bool {
	session.ptyWriteMu.Lock()
	defer session.ptyWriteMu.Unlock()

	h.mu.Lock()
	current := h.sessions[session.id] == session && !session.closed && len(session.attachments) > 0
	cols := session.effectiveCols
	rows := session.effectiveRows
	h.mu.Unlock()
	if !current || cols <= 0 || rows <= 0 {
		return false
	}

	h.applyPTYSizeWithWriteLock(session, cols, rows)
	return true
}

func (h *wsPTYHub) applyPTYSizeWithWriteLock(session *wsPTYSession, cols int, rows int) bool {
	desired := &pty.Winsize{
		Cols: uint16(cols),
		Rows: uint16(rows),
	}
	var lastErr error
	for attempt := 0; attempt < 8; attempt++ {
		resizeFile := session.ptyFile
		if session.ttyFile != nil {
			resizeFile = session.ttyFile
		}
		lastErr = pty.Setsize(resizeFile, desired)
		if lastErr != nil {
			continue
		}
		actual, err := pty.GetsizeFull(resizeFile)
		if err != nil {
			lastErr = err
			continue
		}
		if int(actual.Cols) == cols && int(actual.Rows) == rows {
			return true
		}
		lastErr = fmt.Errorf("pty size remained %dx%d after resize to %dx%d", actual.Cols, actual.Rows, cols, rows)
	}
	if h.stderr != nil && lastErr != nil {
		_, _ = fmt.Fprintf(h.stderr, "ws pty resize failed session=%s: %v\n", session.id, lastErr)
	}
	return false
}

func (h *wsPTYHub) writeInput(attachment *wsPTYAttachment, payload []byte) bool {
	session := h.sessionForAttachment(attachment.sessionID)
	if session == nil {
		return false
	}

	session.ptyWriteMu.Lock()
	defer session.ptyWriteMu.Unlock()

	h.mu.Lock()
	current := h.sessions[attachment.sessionID] == session &&
		!session.closed &&
		session.attachments[attachment.id] == attachment
	cols := session.effectiveCols
	rows := session.effectiveRows
	h.mu.Unlock()
	if !current {
		return false
	}
	if cols > 0 && rows > 0 {
		h.applyPTYSizeWithWriteLock(session, cols, rows)
	}
	total := 0
	for total < len(payload) {
		n, err := session.ptyFile.Write(payload[total:])
		if n > 0 {
			total += n
		}
		if err != nil {
			return false
		}
		if n == 0 {
			return false
		}
	}
	return true
}

func (h *wsPTYHub) sessionForAttachment(sessionID string) *wsPTYSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[sessionID]
	if session == nil || session.closed {
		return nil
	}
	return session
}

func (h *wsPTYHub) resize(attachment *wsPTYAttachment, cols int, rows int) {
	if cols <= 0 || rows <= 0 {
		return
	}
	cols, rows = normalizePTYSize(cols, rows)
	h.mu.Lock()

	session := h.sessions[attachment.sessionID]
	if session == nil || session.closed {
		h.mu.Unlock()
		return
	}
	current := session.attachments[attachment.id]
	if current != attachment {
		h.mu.Unlock()
		return
	}
	current.cols = cols
	current.rows = rows
	shouldApplySize := h.recomputeSessionSizeLocked(session)
	h.mu.Unlock()

	if shouldApplySize {
		h.applyCurrentPTYSize(session)
	}
}

func (a *wsPTYAttachment) enqueueBinary(payload []byte) bool {
	return a.enqueue(websocket.MessageBinary, payload)
}

func (a *wsPTYAttachment) enqueueJSON(payload any) bool {
	data, err := json.Marshal(payload)
	if err != nil {
		a.cancel()
		return false
	}
	return a.enqueue(websocket.MessageText, data)
}

func (a *wsPTYAttachment) enqueueReady(sessionID string) bool {
	return a.enqueueJSON(wsPTYEventFrame{
		Type:         "ready",
		SessionID:    sessionID,
		AttachmentID: a.id,
	})
}

func (a *wsPTYAttachment) enqueue(messageType websocket.MessageType, payload []byte) bool {
	frame := wsPTYOutgoingFrame{
		messageType: messageType,
		payload:     append([]byte(nil), payload...),
	}
	select {
	case a.send <- frame:
		return true
	default:
		a.cancel()
		return false
	}
}

func (a *wsPTYAttachment) writeLoop(ctx context.Context, conn *websocket.Conn, sessionDone <-chan struct{}) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-sessionDone:
			for {
				select {
				case frame := <-a.send:
					if !a.writeFrame(ctx, conn, frame) {
						return
					}
				default:
					_ = conn.Close(websocket.StatusNormalClosure, "pty closed")
					return
				}
			}
		case frame := <-a.send:
			if !a.writeFrame(ctx, conn, frame) {
				return
			}
		}
	}
}

func (a *wsPTYAttachment) writeFrame(ctx context.Context, conn *websocket.Conn, frame wsPTYOutgoingFrame) bool {
	writeCtx, cancel := context.WithTimeout(ctx, defaultWebSocketWriteTimeout)
	err := conn.Write(writeCtx, frame.messageType, frame.payload)
	cancel()
	if err != nil {
		a.cancel()
		return false
	}
	return true
}

func (a *wsPTYAttachment) closeNow() {
	if a == nil || a.conn == nil {
		return
	}
	_ = a.conn.CloseNow()
}

func pumpWebSocketToPTY(ctx context.Context, hub *wsPTYHub, attachment *wsPTYAttachment, conn *websocket.Conn) {
	for {
		msgType, payload, err := conn.Read(ctx)
		if err != nil {
			return
		}
		switch msgType {
		case websocket.MessageBinary:
			if ok := hub.writeInput(attachment, payload); !ok {
				return
			}
		case websocket.MessageText:
			var control wsPTYControlFrame
			if err := json.Unmarshal(payload, &control); err != nil {
				continue
			}
			switch control.Type {
			case "resize":
				hub.resize(attachment, control.Cols, control.Rows)
			case "close":
				return
			}
		}
	}
}

func normalizePTYSize(cols int, rows int) (int, int) {
	if cols <= 0 {
		cols = defaultPTYCols
	}
	if rows <= 0 {
		rows = defaultPTYRows
	}
	if cols > maxPTYDimension {
		cols = maxPTYDimension
	}
	if rows > maxPTYDimension {
		rows = maxPTYDimension
	}
	return cols, rows
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
