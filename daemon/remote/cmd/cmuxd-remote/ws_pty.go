package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
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
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/creack/pty"
	"nhooyr.io/websocket"
)

type wsPTYServerConfig struct {
	ListenAddr          string
	PTYAuthLeaseFile    string
	RPCAuthLeaseFile    string
	AdminTokenSHA256    string
	AdminEd25519PubKey  string
	CLIBridgeSocketPath string
	CLIBridge           *cloudCLIBridge
	Shell               string
	PTYHub              *wsPTYHub
	ScrollbackLimit     int
	SessionIdleTTL      time.Duration
}

type wsLease struct {
	Version       int    `json:"version"`
	TokenSHA256   string `json:"token_sha256"`
	ExpiresAtUnix int64  `json:"expires_at_unix"`
	SessionID     string `json:"session_id,omitempty"`
	SingleUse     bool   `json:"single_use"`
}

type wsLeaseInstallRequest struct {
	PTYLease  *wsLease            `json:"pty_lease,omitempty"`
	RPCLease  *wsLease            `json:"rpc_lease,omitempty"`
	RPCClient *wsRPCClientPayload `json:"rpc_client,omitempty"`
}

type wsRPCClientPayload struct {
	Token         string `json:"token"`
	SessionID     string `json:"sessionId"`
	ExpiresAtUnix int64  `json:"expiresAtUnix"`
}

type wsAuthFrame struct {
	Type              string `json:"type"`
	Token             string `json:"token"`
	SessionID         string `json:"session_id,omitempty"`
	AttachmentID      string `json:"attachment_id,omitempty"`
	Cols              int    `json:"cols,omitempty"`
	Rows              int    `json:"rows,omitempty"`
	SessionIDExplicit bool   `json:"-"`
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
	defaultPTYCols                   = 80
	defaultPTYRows                   = 24
	maxPTYDimension                  = 65535
	defaultWebSocketScrollbackCap    = 1 << 20
	defaultWebSocketReplayChunkBytes = 48 * 1024
	defaultWebSocketWriteQueueCap    = 256
	defaultPTYInputQueueCap          = 256
	defaultPTYInputChunkBytes        = 16 * 1024
	defaultWebSocketWriteTimeout     = 10 * time.Second
	defaultWebSocketSessionIdleTTL   = 24 * time.Hour
)

type wsPTYOutgoingFrame struct {
	messageType websocket.MessageType
	payload     []byte
}

type wsPTYInputChunk struct {
	attachmentID string
	attachment   *wsPTYAttachment
	payload      []byte
}

type wsPTYInputWriteStatus uint8

const (
	wsPTYInputWriteOK wsPTYInputWriteStatus = iota
	wsPTYInputWriteNotFound
	wsPTYInputWriteQueueFull
)

type wsPTYAttachment struct {
	sessionKey  wsPTYSessionKey
	id          string
	clientToken string
	cols        int
	rows        int
	send        chan wsPTYOutgoingFrame
	cancel      context.CancelFunc
	conn        *websocket.Conn
	persistent  bool
}

type wsPTYSessionKey struct {
	kind        wsPTYSessionKind
	sessionID   string
	anonymousID uint64
}

type wsPTYSessionKind uint8

const (
	wsPTYPersistentSession wsPTYSessionKind = iota
	wsPTYAnonymousSession
)

func persistentPTYSessionKey(sessionID string) wsPTYSessionKey {
	return wsPTYSessionKey{kind: wsPTYPersistentSession, sessionID: sessionID}
}

func anonymousPTYSessionKey(sessionID string, anonymousID uint64) wsPTYSessionKey {
	return wsPTYSessionKey{kind: wsPTYAnonymousSession, sessionID: sessionID, anonymousID: anonymousID}
}

type wsPTYSession struct {
	id             string
	key            wsPTYSessionKey
	cmd            *exec.Cmd
	tmpScript      string // temp file path for large startup scripts; cleaned up on exit
	ptyFile        *os.File
	ttyFile        *os.File
	attachments    map[string]*wsPTYAttachment
	effectiveCols  int
	effectiveRows  int
	lastKnownCols  int
	lastKnownRows  int
	resizeConfirms int
	scrollback     []byte
	input          chan wsPTYInputChunk
	inputEnqueueMu sync.Mutex
	done           chan struct{}
	idleTimer      *time.Timer
	closed         bool
	ptyWriteMu     sync.Mutex
	closeTTYOnce   sync.Once
	closePTYOnce   sync.Once
}

type wsPTYHub struct {
	mu               sync.Mutex
	sessions         map[wsPTYSessionKey]*wsPTYSession
	nextAttachmentID uint64
	nextAnonymousID  uint64
	shell            string
	stderr           io.Writer
	scrollbackLimit  int
	sessionIdleTTL   time.Duration
	// openPTY allocates a PTY master/slave pair. It defaults to creack/pty.Open
	// (which opens /dev/ptmx) and exists as a field so tests can simulate a
	// hardened devpts where allocation is denied.
	openPTY ptyOpener
}

// ptyOpener allocates a PTY master/slave pair, returning the master (ptmx) and
// slave (tty) ends. The production implementation is creack/pty.Open.
type ptyOpener func() (ptmx *os.File, tty *os.File, err error)

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
		sessions:        map[wsPTYSessionKey]*wsPTYSession{},
		shell:           strings.TrimSpace(cfg.Shell),
		stderr:          stderr,
		scrollbackLimit: limit,
		sessionIdleTTL:  idleTTL,
		openPTY:         pty.Open,
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
	if strings.TrimSpace(cfg.RPCAuthLeaseFile) != "" {
		if cfg.CLIBridge == nil {
			cfg.CLIBridge = newCloudCLIBridge()
		}
		if err := cfg.CLIBridge.start(ctx, cfg.CLIBridgeSocketPath, stderr); err != nil {
			return fmt.Errorf("cloud CLI bridge: %w", err)
		}
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
	mux.HandleFunc("/admin/leases", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocketLeaseInstall(w, r, cfg)
	})
	return mux
}

func handleWebSocketLeaseInstall(w http.ResponseWriter, r *http.Request, cfg wsPTYServerConfig) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	expectedHash, err := hex.DecodeString(strings.TrimSpace(cfg.AdminTokenSHA256))
	publicKey, publicKeyErr := decodeAdminEd25519PublicKey(cfg.AdminEd25519PubKey)
	if (err != nil || len(expectedHash) != sha256.Size) && publicKeyErr != nil {
		http.Error(w, "lease install disabled", http.StatusNotFound)
		return
	}
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body failed", http.StatusBadRequest)
		return
	}
	if !verifyAdminLeaseInstallAuth(r, body, expectedHash, publicKey) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var request wsLeaseInstallRequest
	if err := json.Unmarshal(body, &request); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if request.PTYLease == nil && request.RPCLease == nil {
		http.Error(w, "missing lease", http.StatusBadRequest)
		return
	}
	if request.PTYLease != nil {
		if err := writeLeaseFile(cfg.PTYAuthLeaseFile, request.PTYLease); err != nil {
			http.Error(w, "write pty lease failed", http.StatusInternalServerError)
			return
		}
	}
	if request.RPCLease != nil {
		if strings.TrimSpace(cfg.RPCAuthLeaseFile) == "" {
			http.Error(w, "rpc lease disabled", http.StatusBadRequest)
			return
		}
		if err := writeLeaseFile(cfg.RPCAuthLeaseFile, request.RPCLease); err != nil {
			http.Error(w, "write rpc lease failed", http.StatusInternalServerError)
			return
		}
	}
	if request.RPCClient != nil {
		if err := writeJSONFile("/tmp/cmux/attach-rpc-client.json", request.RPCClient); err != nil {
			http.Error(w, "write rpc client failed", http.StatusInternalServerError)
			return
		}
	}
	w.Header().Set("content-type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func decodeAdminEd25519PublicKey(raw string) (ed25519.PublicKey, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, errors.New("missing ed25519 public key")
	}
	decoded, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(trimmed)
	}
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errors.New("invalid ed25519 public key")
	}
	return ed25519.PublicKey(decoded), nil
}

func verifyAdminLeaseInstallAuth(r *http.Request, body []byte, expectedHash []byte, publicKey ed25519.PublicKey) bool {
	const bearerPrefix = "Bearer "
	auth := r.Header.Get("Authorization")
	if len(expectedHash) == sha256.Size && strings.HasPrefix(auth, bearerPrefix) {
		actualHash := sha256.Sum256([]byte(strings.TrimPrefix(auth, bearerPrefix)))
		if subtle.ConstantTimeCompare(expectedHash, actualHash[:]) == 1 {
			return true
		}
	}
	if len(publicKey) == ed25519.PublicKeySize {
		signatureRaw := strings.TrimSpace(r.Header.Get("X-Cmux-Admin-Signature-Ed25519"))
		signature, err := base64.StdEncoding.DecodeString(signatureRaw)
		if err != nil {
			signature, err = base64.RawStdEncoding.DecodeString(signatureRaw)
		}
		if err == nil && len(signature) == ed25519.SignatureSize && ed25519.Verify(publicKey, body, signature) {
			return true
		}
	}
	return false
}

func writeLeaseFile(path string, lease *wsLease) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("lease path is empty")
	}
	return writeJSONFile(path, lease)
}

func writeJSONFile(path string, value any) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0o600)
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
	auth.SessionID = strings.TrimSpace(auth.SessionID)
	auth.SessionIDExplicit = auth.SessionID != ""
	auth.Cols, auth.Rows = normalizePTYSize(auth.Cols, auth.Rows)
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

	attachment, err := cfg.PTYHub.attach(r.Context(), conn, auth)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ws pty attach failed: %v\n", err)
		_ = conn.Close(websocket.StatusInternalError, truncateWebSocketCloseReason(err.Error()))
		return
	}
	defer func() {
		if attachment.persistent {
			cfg.PTYHub.detach(attachment)
		} else {
			cfg.PTYHub.closeSessionForAttachment(attachment)
		}
	}()

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
		ptyHub:        cfg.PTYHub,
		ownsPTYHub:    false,
		cliBridge:     cfg.CLIBridge,
		frameWriter: &wsRPCFrameWriter{
			conn:    conn,
			writeMu: writeMu,
			ctx:     r.Context(),
		},
	}
	unregisterCLI := func() {}
	if cfg.CLIBridge != nil {
		unregisterCLI = cfg.CLIBridge.register(server)
	}
	defer unregisterCLI()
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

		if err := server.handleRequestAndWriteResponse(req); err != nil {
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
	attachmentID := strings.TrimSpace(auth.AttachmentID)
	persistent := attachmentID != "" && auth.SessionIDExplicit
	attachment, attachmentCtx, sessionDone, err := h.prepareAttachment(
		ctx,
		conn,
		sessionID,
		attachmentID,
		cols,
		rows,
		persistent,
		"",
		"",
		false,
	)
	if err != nil {
		return nil, err
	}
	go attachment.writeLoop(attachmentCtx, conn, sessionDone)
	return attachment, nil
}

func (h *wsPTYHub) attachRPC(
	ctx context.Context,
	sessionID string,
	attachmentID string,
	cols int,
	rows int,
	command string,
	clientToken string,
	requireExisting bool,
) (*wsPTYAttachment, context.Context, <-chan struct{}, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return nil, nil, nil, errors.New("session_id is required")
	}
	attachmentID = strings.TrimSpace(attachmentID)
	cols, rows = normalizePTYSize(cols, rows)
	return h.prepareAttachment(ctx, nil, sessionID, attachmentID, cols, rows, true, command, clientToken, requireExisting)
}

func (h *wsPTYHub) prepareAttachment(
	ctx context.Context,
	conn *websocket.Conn,
	sessionID string,
	attachmentID string,
	cols int,
	rows int,
	persistent bool,
	command string,
	clientToken string,
	requireExisting bool,
) (*wsPTYAttachment, context.Context, <-chan struct{}, error) {
	h.mu.Lock()

	sessionKey := persistentPTYSessionKey(sessionID)
	if !persistent {
		sessionKey = anonymousPTYSessionKey(sessionID, h.nextAnonymousID)
		h.nextAnonymousID++
	}
	session := h.sessions[sessionKey]
	if session == nil || session.closed {
		if requireExisting {
			h.mu.Unlock()
			return nil, nil, nil, fmt.Errorf("persistent PTY session %q is not running", sessionID)
		}
		var err error
		session, err = h.startSessionLocked(sessionKey, sessionID, cols, rows, command)
		if err != nil {
			h.mu.Unlock()
			return nil, nil, nil, err
		}
		h.sessions[sessionKey] = session
	}

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
	clientToken = strings.TrimSpace(clientToken)
	attachment := &wsPTYAttachment{
		sessionKey:  sessionKey,
		id:          attachmentID,
		clientToken: clientToken,
		cols:        cols,
		rows:        rows,
		send:        make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:      cancel,
		conn:        conn,
		persistent:  persistent,
	}
	replay := append([]byte(nil), session.scrollback...)
	if ok := attachment.enqueueReady(sessionID); !ok {
		cancel()
		h.mu.Unlock()
		if superseded != nil {
			superseded.closeNow()
		}
		return nil, nil, nil, errors.New("failed to queue ready frame")
	}
	if ok := enqueuePTYReplay(attachment, replay); !ok {
		cancel()
		h.mu.Unlock()
		if superseded != nil {
			superseded.closeNow()
		}
		return nil, nil, nil, errors.New("failed to queue replay frame")
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
	return attachment, attachmentCtx, sessionDone, nil
}

func (h *wsPTYHub) startSessionLocked(sessionKey wsPTYSessionKey, sessionID string, cols int, rows int, command string) (*wsPTYSession, error) {
	shellPath := resolvePTYShell(h.shell)
	trimmedCommand := strings.TrimSpace(command)
	var cmd *exec.Cmd
	var tmpScript string
	if trimmedCommand == "" {
		cmd = exec.Command(shellPath)
	} else if len(trimmedCommand) > 120*1024 {
		// Startup script exceeds Linux's MAX_ARG_STRLEN (~128KB). Write to a
		// temp file and exec /bin/sh <file> to avoid E2BIG from execve.
		f, err := os.CreateTemp("", "cmuxd-startup-*.sh")
		if err != nil {
			return nil, fmt.Errorf("could not create startup script temp file: %w", err)
		}
		tmpScript = f.Name()
		if _, err := f.WriteString(trimmedCommand); err != nil {
			_ = f.Close()
			_ = os.Remove(tmpScript)
			return nil, fmt.Errorf("could not write startup script: %w", err)
		}
		_ = f.Chmod(0o400)
		_ = f.Close()
		cmd = exec.Command("/bin/sh", tmpScript)
	} else {
		cmd = exec.Command("/bin/sh", "-c", trimmedCommand)
	}
	cmd.Env = defaultWebSocketPTYEnv(shellPath)
	ptyFile, ttyFile, err := h.startPTYCommand(cmd, cols, rows)
	if err != nil {
		if tmpScript != "" {
			_ = os.Remove(tmpScript)
		}
		if h.stderr != nil {
			_, _ = fmt.Fprintf(h.stderr, "pty session start failed session=%s: %v\n", sessionID, err)
		}
		return nil, err
	}
	session := &wsPTYSession{
		id:            sessionID,
		key:           sessionKey,
		cmd:           cmd,
		tmpScript:     tmpScript,
		ptyFile:       ptyFile,
		ttyFile:       ttyFile,
		attachments:   map[string]*wsPTYAttachment{},
		effectiveCols: cols,
		effectiveRows: rows,
		lastKnownCols: cols,
		lastKnownRows: rows,
		input:         make(chan wsPTYInputChunk, defaultPTYInputQueueCap),
		done:          make(chan struct{}),
	}
	go h.waitSessionProcess(session)
	go h.pumpSession(session)
	go h.writeInputLoop(session)
	return session, nil
}

func (h *wsPTYHub) startPTYCommand(cmd *exec.Cmd, cols int, rows int) (*os.File, *os.File, error) {
	open := h.openPTY
	if open == nil {
		open = pty.Open
	}
	ptyFile, ttyFile, err := open()
	if err != nil {
		return nil, nil, newPTYAllocationError(err)
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
	_ = ttyFile.Close()
	return ptyFile, nil, nil
}

// newPTYAllocationError wraps a raw PTY-allocation failure with actionable
// diagnostics about the remote devpts. Without this, a hardened mount
// (ptmxmode=000) or a non-writable /dev/ptmx surfaced only a generic
// "remote PTY attach failed" with a 0-byte daemon log, leaving the operator no
// way to tell why the terminal would not open. See issue #5185.
func newPTYAllocationError(err error) error {
	suffix := ""
	if detail := describeDevPTS(); detail != "" {
		suffix = "; " + detail
	}
	hint := ""
	if isPermissionDeniedErr(err) {
		hint = "; the remote devpts denies /dev/ptmx (e.g. mounted ptmxmode=000): remount it writable with `sudo mount -o remount,ptmxmode=0666 /dev/pts` or expose a writable /dev/ptmx so the cmux daemon can open a terminal"
	}
	return fmt.Errorf("could not allocate a remote PTY: %w%s%s", err, suffix, hint)
}

// describeDevPTS reports the current /dev/ptmx mode and the /dev/pts devpts
// mount options (which carry ptmxmode) on a best-effort basis. It never errors;
// missing data is simply omitted from the returned summary.
func describeDevPTS() string {
	var parts []string
	if info, statErr := os.Stat("/dev/ptmx"); statErr == nil {
		parts = append(parts, fmt.Sprintf("/dev/ptmx mode=%04o", info.Mode().Perm()))
	} else {
		parts = append(parts, fmt.Sprintf("/dev/ptmx stat error: %v", statErr))
	}
	if opts := devptsMountOptions(); opts != "" {
		parts = append(parts, "devpts ("+opts+")")
	}
	return strings.Join(parts, "; ")
}

// devptsMountOptions returns the super-block options of the devpts filesystem
// mounted at /dev/pts (e.g. "rw,gid=5,mode=620,ptmxmode=000"), or "" if it
// cannot be determined. It parses /proc/self/mountinfo, whose per-line layout
// places the optional fields and the " - <fstype> <source> <superopts>" tail
// after a literal " - " separator.
func devptsMountOptions() string {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		// mount point is field index 4 (0-based) in the pre-separator section.
		if len(fields) < 5 || fields[4] != "/dev/pts" {
			continue
		}
		sep := -1
		for i, f := range fields {
			if f == "-" {
				sep = i
				break
			}
		}
		if sep < 0 || sep+3 >= len(fields) {
			continue
		}
		if fields[sep+1] != "devpts" {
			continue
		}
		return fields[sep+3]
	}
	return ""
}

// truncateWebSocketCloseReason clamps a close reason to the 123-byte limit a
// WebSocket control frame allows for its UTF-8 reason payload, trimming on a
// rune boundary so the frame stays valid.
func truncateWebSocketCloseReason(reason string) string {
	const maxReasonBytes = 123
	if len(reason) <= maxReasonBytes {
		return reason
	}
	truncated := reason[:maxReasonBytes]
	for len(truncated) > 0 && !utf8.ValidString(truncated) {
		truncated = truncated[:len(truncated)-1]
	}
	return truncated
}

// isPermissionDeniedErr reports whether err is an EACCES/EPERM-class failure,
// the signature of a devpts that refuses /dev/ptmx.
func isPermissionDeniedErr(err error) bool {
	return errors.Is(err, os.ErrPermission) ||
		errors.Is(err, syscall.EACCES) ||
		errors.Is(err, syscall.EPERM)
}

func (h *wsPTYHub) detach(attachment *wsPTYAttachment) bool {
	if attachment == nil {
		return false
	}
	h.mu.Lock()

	session := h.sessions[attachment.sessionKey]
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
	if attachment.persistent {
		h.detach(attachment)
	} else {
		h.closeSessionForAttachment(attachment)
	}
	attachment.closeNow()
}

func (h *wsPTYHub) closeSessionForAttachment(attachment *wsPTYAttachment) {
	if attachment == nil {
		return
	}
	h.mu.Lock()
	session := h.sessions[attachment.sessionKey]
	if session == nil || session.attachments[attachment.id] != attachment {
		h.mu.Unlock()
		return
	}
	delete(h.sessions, session.key)
	delete(session.attachments, attachment.id)
	h.cancelIdleReapLocked(session)
	attachment.cancel()
	h.mu.Unlock()

	if session.cmd != nil && session.cmd.Process != nil {
		_ = session.cmd.Process.Kill()
	}
	session.closePTYFiles()
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

func (h *wsPTYHub) writeInputByID(sessionID string, attachmentID string, attachmentToken string, payload []byte) wsPTYInputWriteStatus {
	attachment := h.attachmentByID(sessionID, attachmentID, attachmentToken)
	if attachment == nil {
		return wsPTYInputWriteNotFound
	}
	return h.writeInput(attachment, payload)
}

func (h *wsPTYHub) resizeByID(sessionID string, attachmentID string, attachmentToken string, cols int, rows int) bool {
	attachment := h.attachmentByID(sessionID, attachmentID, attachmentToken)
	if attachment == nil {
		return false
	}
	h.resize(attachment, cols, rows)
	return true
}

func (h *wsPTYHub) detachByID(sessionID string, attachmentID string, attachmentToken string) bool {
	attachment := h.attachmentByID(sessionID, attachmentID, attachmentToken)
	if attachment == nil {
		return false
	}
	return h.detach(attachment)
}

func (h *wsPTYHub) closeSessionByID(sessionID string) bool {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return false
	}
	sessionKey := persistentPTYSessionKey(sessionID)

	h.mu.Lock()
	session := h.sessions[sessionKey]
	if session == nil || session.closed {
		h.mu.Unlock()
		return false
	}
	delete(h.sessions, sessionKey)
	h.cancelIdleReapLocked(session)
	session.closed = true
	h.mu.Unlock()

	if session.cmd != nil && session.cmd.Process != nil {
		_ = session.cmd.Process.Kill()
	}
	session.closePTYFiles()
	return true
}

func (h *wsPTYHub) sessionSnapshots() []map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()

	keys := make([]wsPTYSessionKey, 0, len(h.sessions))
	for key, session := range h.sessions {
		if key.kind == wsPTYPersistentSession && session != nil && !session.closed {
			keys = append(keys, key)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		return keys[i].sessionID < keys[j].sessionID
	})

	snapshots := make([]map[string]any, 0, len(keys))
	for _, key := range keys {
		if session := h.sessions[key]; session != nil {
			snapshots = append(snapshots, h.sessionSnapshotLocked(session))
		}
	}
	return snapshots
}

func (h *wsPTYHub) attachmentByID(sessionID string, attachmentID string, attachmentToken string) *wsPTYAttachment {
	sessionID = strings.TrimSpace(sessionID)
	attachmentID = strings.TrimSpace(attachmentID)
	attachmentToken = strings.TrimSpace(attachmentToken)
	if sessionID == "" || attachmentID == "" {
		return nil
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil || session.closed {
		return nil
	}
	attachment := session.attachments[attachmentID]
	if attachment == nil ||
		subtle.ConstantTimeCompare([]byte(attachment.clientToken), []byte(attachmentToken)) != 1 {
		return nil
	}
	return attachment
}

func (h *wsPTYHub) sessionSnapshotLocked(session *wsPTYSession) map[string]any {
	attachmentIDs := make([]string, 0, len(session.attachments))
	for attachmentID := range session.attachments {
		attachmentIDs = append(attachmentIDs, attachmentID)
	}
	sort.Strings(attachmentIDs)

	attachments := make([]map[string]any, 0, len(attachmentIDs))
	for _, attachmentID := range attachmentIDs {
		attachment := session.attachments[attachmentID]
		attachments = append(attachments, map[string]any{
			"attachment_id": attachmentID,
			"cols":          attachment.cols,
			"rows":          attachment.rows,
			"persistent":    attachment.persistent,
		})
	}

	return map[string]any{
		"session_id":       session.id,
		"attachments":      attachments,
		"effective_cols":   session.effectiveCols,
		"effective_rows":   session.effectiveRows,
		"last_known_cols":  session.lastKnownCols,
		"last_known_rows":  session.lastKnownRows,
		"scrollback_bytes": len(session.scrollback),
	}
}

func (h *wsPTYHub) waitSessionProcess(session *wsPTYSession) {
	if session.cmd != nil {
		_ = session.cmd.Wait()
	}
	if session.tmpScript != "" {
		_ = os.Remove(session.tmpScript)
	}
	session.closeTTYFile()
}

func (session *wsPTYSession) closePTYFiles() {
	session.closeTTYFile()
	session.closePTYFile()
}

func (session *wsPTYSession) closeTTYFile() {
	session.closeTTYOnce.Do(func() {
		if session.ttyFile != nil {
			_ = session.ttyFile.Close()
			session.ttyFile = nil
		}
	})
}

func (session *wsPTYSession) closePTYFile() {
	session.closePTYOnce.Do(func() {
		if session.ptyFile != nil {
			_ = session.ptyFile.Close()
		}
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
			continue
		}
	}
}

func (h *wsPTYHub) finishSession(session *wsPTYSession) {
	session.closePTYFiles()

	h.mu.Lock()
	if h.sessions[session.key] == session {
		delete(h.sessions, session.key)
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
	if session.effectiveCols == minCols && session.effectiveRows == minRows {
		session.lastKnownCols = minCols
		session.lastKnownRows = minRows
		return false
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
	if h.sessions[session.key] != session || session.closed || len(session.attachments) > 0 {
		h.mu.Unlock()
		return
	}
	delete(h.sessions, session.key)
	session.idleTimer = nil
	h.mu.Unlock()

	if session.cmd != nil && session.cmd.Process != nil {
		_ = session.cmd.Process.Kill()
	}
	session.closePTYFiles()
}

func (h *wsPTYHub) confirmPTYSizeAfterOutput(session *wsPTYSession) {
	h.mu.Lock()
	if h.sessions[session.key] != session || session.closed || session.resizeConfirms <= 0 {
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
	current := h.sessions[session.key] == session && !session.closed && len(session.attachments) > 0
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

func (h *wsPTYHub) writeInput(attachment *wsPTYAttachment, payload []byte) wsPTYInputWriteStatus {
	session := h.sessionForAttachment(attachment.sessionKey)
	if session == nil {
		return wsPTYInputWriteNotFound
	}
	if len(payload) == 0 {
		return wsPTYInputWriteOK
	}

	h.mu.Lock()
	current := h.sessions[attachment.sessionKey] == session &&
		!session.closed &&
		session.attachments[attachment.id] == attachment &&
		session.input != nil
	h.mu.Unlock()
	if !current {
		return wsPTYInputWriteNotFound
	}

	chunks := make([]wsPTYInputChunk, 0, (len(payload)+defaultPTYInputChunkBytes-1)/defaultPTYInputChunkBytes)
	for len(payload) > 0 {
		chunkLen := len(payload)
		if chunkLen > defaultPTYInputChunkBytes {
			chunkLen = defaultPTYInputChunkBytes
		}
		chunks = append(chunks, wsPTYInputChunk{
			attachmentID: attachment.id,
			attachment:   attachment,
			payload:      append([]byte(nil), payload[:chunkLen]...),
		})
		payload = payload[chunkLen:]
	}

	session.inputEnqueueMu.Lock()
	defer session.inputEnqueueMu.Unlock()

	h.mu.Lock()
	current = h.sessions[attachment.sessionKey] == session &&
		!session.closed &&
		session.attachments[attachment.id] == attachment &&
		session.input != nil
	h.mu.Unlock()
	if !current {
		return wsPTYInputWriteNotFound
	}
	if len(chunks) > cap(session.input)-len(session.input) {
		if h.stderr != nil {
			_, _ = fmt.Fprintf(h.stderr, "ws pty input queue full session=%s attachment=%s\n", session.id, attachment.id)
		}
		return wsPTYInputWriteQueueFull
	}
	for _, chunk := range chunks {
		select {
		case session.input <- chunk:
		case <-session.done:
			return wsPTYInputWriteNotFound
		}
	}
	return wsPTYInputWriteOK
}

func (h *wsPTYHub) writeInputLoop(session *wsPTYSession) {
	for {
		select {
		case <-session.done:
			return
		case chunk := <-session.input:
			h.writeInputChunk(session, chunk)
		}
	}
}

func (h *wsPTYHub) writeInputChunk(session *wsPTYSession, chunk wsPTYInputChunk) bool {
	session.ptyWriteMu.Lock()
	defer session.ptyWriteMu.Unlock()

	h.mu.Lock()
	current := h.sessions[session.key] == session &&
		!session.closed &&
		session.attachments[chunk.attachmentID] == chunk.attachment
	ptyFile := session.ptyFile
	h.mu.Unlock()
	if !current || ptyFile == nil {
		return false
	}
	total := 0
	for total < len(chunk.payload) {
		n, err := ptyFile.Write(chunk.payload[total:])
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

func (h *wsPTYHub) sessionForAttachment(sessionKey wsPTYSessionKey) *wsPTYSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[sessionKey]
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

	session := h.sessions[attachment.sessionKey]
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

func enqueuePTYReplay(attachment *wsPTYAttachment, replay []byte) bool {
	for start := 0; start < len(replay); start += defaultWebSocketReplayChunkBytes {
		end := start + defaultWebSocketReplayChunkBytes
		if end > len(replay) {
			end = len(replay)
		}
		if ok := attachment.enqueueBinary(replay[start:end]); !ok {
			return false
		}
	}
	return true
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
	if ctx.Err() != nil {
		if a.cancel != nil {
			a.cancel()
		}
		_ = conn.CloseNow()
		return false
	}
	writeCtx, cancel := context.WithTimeout(ctx, defaultWebSocketWriteTimeout)
	err := conn.Write(writeCtx, frame.messageType, frame.payload)
	cancel()
	if err != nil {
		if a.cancel != nil {
			a.cancel()
		}
		_ = conn.CloseNow()
		return false
	}
	return true
}

func rpcPTYEventForFrame(attachment *wsPTYAttachment, frame wsPTYOutgoingFrame) rpcEvent {
	event := rpcEvent{
		Event:           "pty.data",
		SessionID:       attachment.sessionKey.sessionID,
		AttachmentID:    attachment.id,
		AttachmentToken: attachment.clientToken,
	}
	if frame.messageType == websocket.MessageText {
		var wsEvent wsPTYEventFrame
		if err := json.Unmarshal(frame.payload, &wsEvent); err == nil && strings.TrimSpace(wsEvent.Type) != "" {
			event.Event = "pty." + strings.TrimSpace(wsEvent.Type)
			event.Message = wsEvent.Message
			if strings.TrimSpace(wsEvent.SessionID) != "" {
				event.SessionID = strings.TrimSpace(wsEvent.SessionID)
			}
			if strings.TrimSpace(wsEvent.AttachmentID) != "" {
				event.AttachmentID = strings.TrimSpace(wsEvent.AttachmentID)
			}
			event.AttachmentToken = attachment.clientToken
			return event
		}
		event.Event = "pty.message"
		event.Message = string(frame.payload)
		return event
	}
	event.DataBase64 = base64.StdEncoding.EncodeToString(frame.payload)
	return event
}

func rpcPTYExitEvent(attachment *wsPTYAttachment) rpcEvent {
	return rpcEvent{
		Event:           "pty.exit",
		SessionID:       attachment.sessionKey.sessionID,
		AttachmentID:    attachment.id,
		AttachmentToken: attachment.clientToken,
	}
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
			if status := hub.writeInput(attachment, payload); status != wsPTYInputWriteOK {
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
				hub.closeSessionForAttachment(attachment)
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
