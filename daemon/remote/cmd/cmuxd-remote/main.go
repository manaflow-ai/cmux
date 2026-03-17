package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var version = "dev"

type rpcRequest struct {
	ID     any            `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	ID     any       `json:"id,omitempty"`
	OK     bool      `json:"ok"`
	Result any       `json:"result,omitempty"`
	Error  *rpcError `json:"error,omitempty"`
}

type rpcEvent struct {
	Event      string `json:"event"`
	StreamID   string `json:"stream_id,omitempty"`
	DataBase64 string `json:"data_base64,omitempty"`
	Error      string `json:"error,omitempty"`
}

type streamState struct {
	conn          net.Conn
	readerStarted bool
}

type stdioFrameWriter struct {
	mu     sync.Mutex
	writer *bufio.Writer
}

type rpcServer struct {
	mu            sync.Mutex
	nextStreamID  uint64
	nextSessionID uint64
	streams       map[string]*streamState
	sessions      map[string]*sessionState
	frameWriter   *stdioFrameWriter
}

type sessionAttachment struct {
	Cols      int
	Rows      int
	UpdatedAt time.Time
}

type sessionState struct {
	attachments   map[string]sessionAttachment
	effectiveCols int
	effectiveRows int
	lastKnownCols int
	lastKnownRows int
}

const maxRPCFrameBytes = 4 * 1024 * 1024

func main() {
	if shouldRunCLIForInvocation(os.Args[0], os.Args[1:]) {
		os.Exit(runCLI(os.Args[1:]))
	}
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func shouldRunCLIForInvocation(argv0 string, args []string) bool {
	base := filepath.Base(argv0)
	if base == "cmux" {
		return true
	}
	if !strings.HasPrefix(base, "cmuxd-remote") || len(args) == 0 {
		return false
	}
	return !isDaemonEntryCommand(args[0])
}

func isDaemonEntryCommand(arg string) bool {
	switch arg {
	case "version", "serve", "cli":
		return true
	default:
		return false
	}
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		usage(stderr)
		return 2
	}

	switch args[0] {
	case "version":
		_, _ = fmt.Fprintln(stdout, version)
		return 0
	case "serve":
		fs := flag.NewFlagSet("serve", flag.ContinueOnError)
		fs.SetOutput(stderr)
		stdio := fs.Bool("stdio", false, "serve over stdin/stdout")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if !*stdio {
			_, _ = fmt.Fprintln(stderr, "serve requires --stdio")
			return 2
		}
		if err := runStdioServer(stdin, stdout); err != nil {
			_, _ = fmt.Fprintf(stderr, "serve failed: %v\n", err)
			return 1
		}
		return 0
	case "cli":
		return runCLI(args[1:])
	default:
		usage(stderr)
		return 2
	}
}

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage:")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote version")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --stdio")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote cli <command> [args...]")
}

func runStdioServer(stdin io.Reader, stdout io.Writer) error {
	writer := &stdioFrameWriter{
		writer: bufio.NewWriter(stdout),
	}
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		frameWriter:   writer,
	}
	defer server.closeAll()

	reader := bufio.NewReaderSize(stdin, 64*1024)
	defer writer.writer.Flush()

	for {
		line, oversized, readErr := readRPCFrame(reader, maxRPCFrameBytes)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
		if oversized {
			if err := writer.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "request frame exceeds maximum size",
				},
			}); err != nil {
				return err
			}
			continue
		}
		line = bytes.TrimSuffix(line, []byte{'\n'})
		line = bytes.TrimSuffix(line, []byte{'\r'})
		if len(line) == 0 {
			continue
		}

		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			if err := writer.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "invalid JSON request",
				},
			}); err != nil {
				return err
			}
			continue
		}

		resp := server.handleRequest(req)
		if err := writer.writeResponse(resp); err != nil {
			return err
		}
	}
}

func setTCPNoDelay(conn net.Conn) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcpConn.SetNoDelay(true)
}

func readRPCFrame(reader *bufio.Reader, maxBytes int) ([]byte, bool, error) {
	frame := make([]byte, 0, 1024)
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(chunk) > 0 {
			if len(frame)+len(chunk) > maxBytes {
				if errors.Is(err, bufio.ErrBufferFull) {
					if drainErr := discardUntilNewline(reader); drainErr != nil && !errors.Is(drainErr, io.EOF) {
						return nil, false, drainErr
					}
				}
				return nil, true, nil
			}
			frame = append(frame, chunk...)
		}

		if err == nil {
			return frame, false, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) {
			if len(frame) == 0 {
				return nil, false, io.EOF
			}
			return frame, false, nil
		}
		return nil, false, err
	}
}

func discardUntilNewline(reader *bufio.Reader) error {
	for {
		_, err := reader.ReadSlice('\n')
		if err == nil || errors.Is(err, io.EOF) {
			return err
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return err
	}
}

func (w *stdioFrameWriter) writeResponse(resp rpcResponse) error {
	return w.writeJSONFrame(resp)
}

func (w *stdioFrameWriter) writeEvent(event rpcEvent) error {
	return w.writeJSONFrame(event)
}

func (w *stdioFrameWriter) writeJSONFrame(payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if _, err := w.writer.Write(data); err != nil {
		return err
	}
	if err := w.writer.WriteByte('\n'); err != nil {
		return err
	}
	return w.writer.Flush()
}

func (s *rpcServer) handleRequest(req rpcRequest) rpcResponse {
	if req.Method == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_request",
				Message: "method is required",
			},
		}
	}

	switch req.Method {
	case "hello":
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"name":    "cmuxd-remote",
				"version": version,
				"capabilities": []string{
					"session.basic",
					"session.resize.min",
					"proxy.http_connect",
					"proxy.socks5",
					"proxy.stream",
					"proxy.stream.push",
				},
			},
		}
	case "ping":
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"pong": true,
			},
		}
	case "proxy.open":
		return s.handleProxyOpen(req)
	case "proxy.close":
		return s.handleProxyClose(req)
	case "proxy.write":
		return s.handleProxyWrite(req)
	case "proxy.stream.subscribe":
		return s.handleProxyStreamSubscribe(req)
	case "session.open":
		return s.handleSessionOpen(req)
	case "session.close":
		return s.handleSessionClose(req)
	case "session.attach":
		return s.handleSessionAttach(req)
	case "session.resize":
		return s.handleSessionResize(req)
	case "session.detach":
		return s.handleSessionDetach(req)
	case "session.status":
		return s.handleSessionStatus(req)
	default:
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "method_not_found",
				Message: fmt.Sprintf("unknown method %q", req.Method),
			},
		}
	}
}

func (s *rpcServer) handleProxyOpen(req rpcRequest) rpcResponse {
	host, ok := getStringParam(req.Params, "host")
	if !ok || host == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.open requires host",
			},
		}
	}
	port, ok := getIntParam(req.Params, "port")
	if !ok || port <= 0 || port > 65535 {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.open requires port in range 1-65535",
			},
		}
	}

	timeoutMs := 10000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout && parsed >= 0 {
		timeoutMs = parsed
	}

	conn, err := net.DialTimeout(
		"tcp",
		net.JoinHostPort(host, strconv.Itoa(port)),
		time.Duration(timeoutMs)*time.Millisecond,
	)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "open_failed",
				Message: err.Error(),
			},
		}
	}
	setTCPNoDelay(conn)

	s.mu.Lock()
	streamID := fmt.Sprintf("s-%d", s.nextStreamID)
	s.nextStreamID++
	s.streams[streamID] = &streamState{conn: conn}
	s.mu.Unlock()

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"stream_id": streamID,
		},
	}
}

func (s *rpcServer) handleProxyClose(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.close requires stream_id",
			},
		}
	}

	s.mu.Lock()
	state, exists := s.streams[streamID]
	if exists {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()

	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"closed": true,
			},
		}
	}

	_ = state.conn.Close()
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"closed": true,
		},
	}
}

func (s *rpcServer) handleProxyWrite(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.write requires stream_id",
			},
		}
	}
	dataBase64, ok := getStringParam(req.Params, "data_base64")
	if !ok {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.write requires data_base64",
			},
		}
	}
	payload, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "data_base64 must be valid base64",
			},
		}
	}

	state, found := s.getStream(streamID)
	if !found {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}
	conn := state.conn

	timeoutMs := 8000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout {
		timeoutMs = parsed
	}
	if timeoutMs > 0 {
		if err := conn.SetWriteDeadline(time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)); err != nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: err.Error(),
				},
			}
		}
		defer conn.SetWriteDeadline(time.Time{})
	}

	total := 0
	for total < len(payload) {
		written, writeErr := conn.Write(payload[total:])
		if written == 0 && writeErr == nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: "write made no progress",
				},
			}
		}
		total += written
		if writeErr != nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: writeErr.Error(),
				},
			}
		}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"written": total,
		},
	}
}

func (s *rpcServer) handleProxyStreamSubscribe(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.stream.subscribe requires stream_id",
			},
		}
	}

	s.mu.Lock()
	state, found := s.streams[streamID]
	if !found {
		s.mu.Unlock()
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}
	alreadySubscribed := state.readerStarted
	if !alreadySubscribed {
		state.readerStarted = true
	}
	conn := state.conn
	s.mu.Unlock()

	if !alreadySubscribed {
		go s.streamPump(streamID, conn)
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"subscribed":         true,
			"already_subscribed": alreadySubscribed,
		},
	}
}

func (s *rpcServer) handleSessionOpen(req rpcRequest) rpcResponse {
	sessionID, _ := getStringParam(req.Params, "session_id")

	s.mu.Lock()
	defer s.mu.Unlock()

	if sessionID == "" {
		sessionID = fmt.Sprintf("sess-%d", s.nextSessionID)
		s.nextSessionID++
	}

	session, exists := s.sessions[sessionID]
	if !exists {
		session = &sessionState{
			attachments: map[string]sessionAttachment{},
		}
		s.sessions[sessionID] = session
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionClose(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.close requires session_id",
			},
		}
	}

	s.mu.Lock()
	_, exists := s.sessions[sessionID]
	if exists {
		delete(s.sessions, sessionID)
	}
	s.mu.Unlock()

	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id": sessionID,
			"closed":     true,
		},
	}
}

func (s *rpcServer) handleSessionAttach(req rpcRequest) rpcResponse {
	sessionID, attachmentID, cols, rows, badResp := parseSessionAttachmentParams(req, "session.attach")
	if badResp != nil {
		return *badResp
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}

	session.attachments[attachmentID] = sessionAttachment{
		Cols:      cols,
		Rows:      rows,
		UpdatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(session)

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionResize(req rpcRequest) rpcResponse {
	sessionID, attachmentID, cols, rows, badResp := parseSessionAttachmentParams(req, "session.resize")
	if badResp != nil {
		return *badResp
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}
	if _, exists := session.attachments[attachmentID]; !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "attachment not found",
			},
		}
	}

	session.attachments[attachmentID] = sessionAttachment{
		Cols:      cols,
		Rows:      rows,
		UpdatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(session)

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionDetach(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.detach requires session_id",
			},
		}
	}
	attachmentID, ok := getStringParam(req.Params, "attachment_id")
	if !ok || attachmentID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.detach requires attachment_id",
			},
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}
	if _, exists := session.attachments[attachmentID]; !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "attachment not found",
			},
		}
	}

	delete(session.attachments, attachmentID)
	recomputeSessionSize(session)

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionStatus(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.status requires session_id",
			},
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func parseSessionAttachmentParams(req rpcRequest, method string) (sessionID string, attachmentID string, cols int, rows int, badResp *rpcResponse) {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires session_id",
			},
		}
		return "", "", 0, 0, &resp
	}
	attachmentID, ok = getStringParam(req.Params, "attachment_id")
	if !ok || attachmentID == "" {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires attachment_id",
			},
		}
		return "", "", 0, 0, &resp
	}

	cols, ok = getIntParam(req.Params, "cols")
	if !ok || cols <= 0 {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires cols > 0",
			},
		}
		return "", "", 0, 0, &resp
	}
	rows, ok = getIntParam(req.Params, "rows")
	if !ok || rows <= 0 {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires rows > 0",
			},
		}
		return "", "", 0, 0, &resp
	}

	return sessionID, attachmentID, cols, rows, nil
}

func recomputeSessionSize(session *sessionState) {
	if len(session.attachments) == 0 {
		session.effectiveCols = session.lastKnownCols
		session.effectiveRows = session.lastKnownRows
		return
	}

	minCols := 0
	minRows := 0
	for _, attachment := range session.attachments {
		if minCols == 0 || attachment.Cols < minCols {
			minCols = attachment.Cols
		}
		if minRows == 0 || attachment.Rows < minRows {
			minRows = attachment.Rows
		}
	}

	session.effectiveCols = minCols
	session.effectiveRows = minRows
	session.lastKnownCols = minCols
	session.lastKnownRows = minRows
}

func sessionSnapshot(sessionID string, session *sessionState) map[string]any {
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
			"cols":          attachment.Cols,
			"rows":          attachment.Rows,
			"updated_at":    attachment.UpdatedAt.Format(time.RFC3339Nano),
		})
	}

	return map[string]any{
		"session_id":      sessionID,
		"attachments":     attachments,
		"effective_cols":  session.effectiveCols,
		"effective_rows":  session.effectiveRows,
		"last_known_cols": session.lastKnownCols,
		"last_known_rows": session.lastKnownRows,
	}
}

func (s *rpcServer) getStream(streamID string) (*streamState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.streams[streamID]
	return state, ok
}

func (s *rpcServer) dropStream(streamID string) {
	s.mu.Lock()
	state, ok := s.streams[streamID]
	if ok {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()
	if ok {
		_ = state.conn.Close()
	}
}

func (s *rpcServer) closeAll() {
	s.mu.Lock()
	streams := make([]net.Conn, 0, len(s.streams))
	for id, state := range s.streams {
		delete(s.streams, id)
		streams = append(streams, state.conn)
	}
	for id := range s.sessions {
		delete(s.sessions, id)
	}
	s.mu.Unlock()
	for _, conn := range streams {
		_ = conn.Close()
	}
}

func (s *rpcServer) streamPump(streamID string, conn net.Conn) {
	defer func() {
		if recovered := recover(); recovered != nil {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "proxy.stream.error",
				StreamID: streamID,
				Error:    fmt.Sprintf("stream panic: %v", recovered),
			})
			s.dropStream(streamID)
		}
	}()

	buffer := make([]byte, 32768)
	for {
		n, readErr := conn.Read(buffer)
		data := append([]byte(nil), buffer[:max(0, n)]...)
		if len(data) > 0 {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:      "proxy.stream.data",
				StreamID:   streamID,
				DataBase64: base64.StdEncoding.EncodeToString(data),
			})
		}

		if readErr == nil {
			if n == 0 {
				_ = s.frameWriter.writeEvent(rpcEvent{
					Event:    "proxy.stream.error",
					StreamID: streamID,
					Error:    "read made no progress",
				})
				s.dropStream(streamID)
				return
			}
			continue
		}

		if readErr == io.EOF {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:      "proxy.stream.eof",
				StreamID:   streamID,
				DataBase64: "",
			})
		} else if !errors.Is(readErr, net.ErrClosed) {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "proxy.stream.error",
				StreamID: streamID,
				Error:    readErr.Error(),
			})
		}

		s.dropStream(streamID)
		return
	}
}

func getStringParam(params map[string]any, key string) (string, bool) {
	if params == nil {
		return "", false
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return "", false
	}
	value, ok := raw.(string)
	return value, ok
}

func getIntParam(params map[string]any, key string) (int, bool) {
	if params == nil {
		return 0, false
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return 0, false
	}
	switch value := raw.(type) {
	case int:
		return value, true
	case int8:
		return int(value), true
	case int16:
		return int(value), true
	case int32:
		return int(value), true
	case int64:
		return int(value), true
	case uint:
		return int(value), true
	case uint8:
		return int(value), true
	case uint16:
		return int(value), true
	case uint32:
		return int(value), true
	case uint64:
		return int(value), true
	case float64:
		if math.Trunc(value) != value {
			return 0, false
		}
		return int(value), true
	case json.Number:
		n, err := value.Int64()
		if err != nil {
			return 0, false
		}
		return int(n), true
	default:
		return 0, false
	}
}
