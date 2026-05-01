package direct

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/internal/auth"
	"github.com/manaflow-ai/cmux/daemon/remote/internal/rpc"
)

var (
	ErrMissingTicket           = errors.New("ticket is required")
	ErrMissingAttachCapability = errors.New("ticket missing session capability")
	ErrMissingTicketNonce      = errors.New("ticket nonce is required")
	ErrMissingTLSConfig        = errors.New("tls listener requires listen address, cert, key, server id, and ticket secret")
	ErrReplayedTicket          = errors.New("ticket nonce already used")
)

type Handshake struct {
	Ticket string `json:"ticket"`
}

type Config struct {
	ServerID     string
	TicketSecret []byte
	CertFile     string
	KeyFile      string
	ListenAddr   string
	Handler      rpc.Handler
}

type Server struct {
	cfg Config

	nonceMu    sync.Mutex
	usedNonces map[string]int64
}

func NewTLSServer(cfg Config) *Server {
	return &Server{
		cfg:        cfg,
		usedNonces: map[string]int64{},
	}
}

func (s *Server) HandleHandshake(ctx context.Context, hs Handshake) error {
	_, err := s.verifyHandshake(ctx, hs)
	return err
}

func (s *Server) verifyHandshake(ctx context.Context, hs Handshake) (auth.TicketClaims, error) {
	var empty auth.TicketClaims

	if err := ctx.Err(); err != nil {
		return empty, err
	}
	if hs.Ticket == "" {
		return empty, ErrMissingTicket
	}

	claims, err := auth.VerifyTicket(hs.Ticket, s.cfg.TicketSecret, s.cfg.ServerID)
	if err != nil {
		return empty, err
	}
	if !hasSessionCapability(claims.Capabilities) {
		return empty, ErrMissingAttachCapability
	}
	if claims.Nonce == "" {
		return empty, ErrMissingTicketNonce
	}
	if err := s.consumeNonce(claims.Nonce, claims.ExpiresAt); err != nil {
		return empty, err
	}
	return claims, nil
}

func (s *Server) Serve(ctx context.Context) error {
	if s.cfg.ListenAddr == "" || s.cfg.CertFile == "" || s.cfg.KeyFile == "" || s.cfg.ServerID == "" || len(s.cfg.TicketSecret) == 0 {
		return ErrMissingTLSConfig
	}

	certificate, err := tls.LoadX509KeyPair(s.cfg.CertFile, s.cfg.KeyFile)
	if err != nil {
		return err
	}

	listener, err := tls.Listen("tcp", s.cfg.ListenAddr, &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{certificate},
	})
	if err != nil {
		return err
	}
	defer listener.Close()

	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) && ctx.Err() != nil {
				return nil
			}
			return err
		}

		go s.serveConn(ctx, conn)
	}
}

func (s *Server) serveConn(ctx context.Context, conn net.Conn) {
	defer conn.Close()

	reader := bufio.NewReaderSize(conn, 64*1024)
	writer := bufio.NewWriter(conn)

	line, oversized, err := rpc.ReadFrame(reader, rpc.MaxFrameBytes)
	if err != nil {
		return
	}
	if oversized {
		_ = rpc.WriteResponse(writer, rpc.Response{
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_request",
				Message: "handshake frame exceeds maximum size",
			},
		})
		return
	}

	line = bytes.TrimSuffix(line, []byte{'\n'})
	line = bytes.TrimSuffix(line, []byte{'\r'})

	var hs Handshake
	if err := json.Unmarshal(line, &hs); err != nil {
		_ = rpc.WriteResponse(writer, rpc.Response{
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_request",
				Message: "invalid JSON handshake",
			},
		})
		return
	}
	claims, err := s.verifyHandshake(ctx, hs)
	if err != nil {
		_ = rpc.WriteResponse(writer, rpc.Response{
			OK: false,
			Error: &rpc.Error{
				Code:    "unauthorized",
				Message: err.Error(),
			},
		})
		return
	}

	_ = rpc.WriteResponse(writer, rpc.Response{
		OK: true,
		Result: map[string]any{
			"authenticated": true,
		},
	})

	if s.cfg.Handler == nil {
		return
	}

	pending := make([]byte, reader.Buffered())
	if len(pending) > 0 {
		if _, err := io.ReadFull(reader, pending); err != nil {
			return
		}
	}

	input := io.Reader(conn)
	if len(pending) > 0 {
		input = io.MultiReader(bytes.NewReader(pending), conn)
	}
	authorizer := newRequestAuthorizer(claims)
	_ = rpc.NewServer(authorizer.wrap(s.cfg.Handler)).Serve(input, conn)
}

type requestGrant int

const (
	requestGrantNone requestGrant = iota
	requestGrantOpen
	requestGrantAttach
)

type requestAuthorizer struct {
	mu                  sync.Mutex
	capabilities        map[string]struct{}
	claimedSessionID    string
	claimedAttachmentID string
	activeSessionID     string
	activeAttachmentID  string
	grant               requestGrant
	used                bool
}

func newRequestAuthorizer(claims auth.TicketClaims) *requestAuthorizer {
	capabilities := make(map[string]struct{}, len(claims.Capabilities))
	for _, capability := range claims.Capabilities {
		capabilities[capability] = struct{}{}
	}
	return &requestAuthorizer{
		capabilities:        capabilities,
		claimedSessionID:    claims.SessionID,
		claimedAttachmentID: claims.AttachmentID,
	}
}

func (a *requestAuthorizer) wrap(next rpc.Handler) rpc.Handler {
	return func(req rpc.Request) rpc.Response {
		if resp, ok := a.authorize(req); !ok {
			resp.ID = req.ID
			return resp
		}

		resp := next(req)
		if resp.OK {
			a.observe(req, resp)
		}
		return resp
	}
}

func (a *requestAuthorizer) authorize(req rpc.Request) (rpc.Response, bool) {
	switch req.Method {
	case "hello", "ping":
		return rpc.Response{}, true
	case "terminal.open":
		return a.authorizeTerminalOpen()
	case "session.attach":
		return a.authorizeSessionAttach(req)
	case "terminal.read", "terminal.write", "session.status", "session.close":
		return a.authorizeEstablishedSession(req, false)
	case "session.resize", "session.detach":
		return a.authorizeEstablishedSession(req, true)
	default:
		return unauthorizedResponse("request is not allowed for this direct ticket"), false
	}
}

func (a *requestAuthorizer) authorizeTerminalOpen() (rpc.Response, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if !a.hasCapabilityLocked("session.open") {
		return unauthorizedResponse("ticket missing session.open capability"), false
	}
	if a.used {
		return unauthorizedResponse("ticket is already bound to a terminal session"), false
	}
	return rpc.Response{}, true
}

func (a *requestAuthorizer) authorizeSessionAttach(req rpc.Request) (rpc.Response, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if !a.hasCapabilityLocked("session.attach") {
		return unauthorizedResponse("ticket missing session.attach capability"), false
	}

	sessionID, hasSessionID := getStringParam(req.Params, "session_id")
	attachmentID, hasAttachmentID := getStringParam(req.Params, "attachment_id")
	if !hasSessionID || sessionID == "" || !hasAttachmentID || attachmentID == "" {
		return rpc.Response{}, true
	}

	expectedSessionID, expectedAttachmentID, ok := a.allowedAttachScopeLocked()
	if !ok {
		return unauthorizedResponse("ticket is not scoped to this session attachment"), false
	}
	if sessionID != expectedSessionID || attachmentID != expectedAttachmentID {
		return unauthorizedResponse("request exceeds direct ticket session scope"), false
	}
	return rpc.Response{}, true
}

func (a *requestAuthorizer) authorizeEstablishedSession(req rpc.Request, needsAttachment bool) (rpc.Response, bool) {
	sessionID, hasSessionID := getStringParam(req.Params, "session_id")
	if !hasSessionID || sessionID == "" {
		return rpc.Response{}, true
	}

	attachmentID := ""
	hasAttachmentID := false
	if needsAttachment {
		attachmentID, hasAttachmentID = getStringParam(req.Params, "attachment_id")
		if !hasAttachmentID || attachmentID == "" {
			return rpc.Response{}, true
		}
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	if a.grant == requestGrantNone || a.activeSessionID == "" {
		return unauthorizedResponse("request requires an opened or attached terminal session"), false
	}
	if sessionID != a.activeSessionID {
		return unauthorizedResponse("request exceeds direct ticket session scope"), false
	}
	if needsAttachment && attachmentID != a.activeAttachmentID {
		return unauthorizedResponse("request exceeds direct ticket attachment scope"), false
	}
	return rpc.Response{}, true
}

func (a *requestAuthorizer) observe(req rpc.Request, resp rpc.Response) {
	a.mu.Lock()
	defer a.mu.Unlock()

	switch req.Method {
	case "terminal.open":
		sessionID, attachmentID, ok := responseSessionScope(resp.Result)
		if !ok {
			return
		}
		a.activeSessionID = sessionID
		a.activeAttachmentID = attachmentID
		a.grant = requestGrantOpen
		a.used = true
	case "session.attach":
		sessionID, ok := getStringParam(req.Params, "session_id")
		if !ok || sessionID == "" {
			return
		}
		attachmentID, ok := getStringParam(req.Params, "attachment_id")
		if !ok || attachmentID == "" {
			return
		}
		a.activeSessionID = sessionID
		a.activeAttachmentID = attachmentID
		a.grant = requestGrantAttach
		a.used = true
	case "session.close", "session.detach":
		a.grant = requestGrantNone
	}
}

func (a *requestAuthorizer) allowedAttachScopeLocked() (sessionID string, attachmentID string, ok bool) {
	if a.grant != requestGrantNone && a.activeSessionID != "" && a.activeAttachmentID != "" {
		return a.activeSessionID, a.activeAttachmentID, true
	}
	if a.claimedSessionID != "" && a.claimedAttachmentID != "" {
		return a.claimedSessionID, a.claimedAttachmentID, true
	}
	return "", "", false
}

func (a *requestAuthorizer) hasCapabilityLocked(capability string) bool {
	_, ok := a.capabilities[capability]
	return ok
}

func unauthorizedResponse(message string) rpc.Response {
	return rpc.Response{
		OK: false,
		Error: &rpc.Error{
			Code:    "unauthorized",
			Message: message,
		},
	}
}

func responseSessionScope(result any) (sessionID string, attachmentID string, ok bool) {
	payload, ok := result.(map[string]any)
	if !ok {
		return "", "", false
	}
	sessionID, ok = payload["session_id"].(string)
	if !ok || sessionID == "" {
		return "", "", false
	}
	attachmentID, ok = payload["attachment_id"].(string)
	if !ok || attachmentID == "" {
		return "", "", false
	}
	return sessionID, attachmentID, true
}

func getStringParam(params map[string]any, key string) (string, bool) {
	if params == nil {
		return "", false
	}
	value, ok := params[key]
	if !ok {
		return "", false
	}
	switch typed := value.(type) {
	case string:
		return typed, true
	default:
		return "", false
	}
}

func (s *Server) consumeNonce(nonce string, expiresAt int64) error {
	now := time.Now().Unix()

	s.nonceMu.Lock()
	defer s.nonceMu.Unlock()

	for existingNonce, existingExpiry := range s.usedNonces {
		if existingExpiry <= now {
			delete(s.usedNonces, existingNonce)
		}
	}
	if _, exists := s.usedNonces[nonce]; exists {
		return ErrReplayedTicket
	}
	s.usedNonces[nonce] = expiresAt
	return nil
}

func hasSessionCapability(capabilities []string) bool {
	for _, capability := range capabilities {
		if capability == "session.attach" || capability == "session.open" {
			return true
		}
	}
	return false
}
