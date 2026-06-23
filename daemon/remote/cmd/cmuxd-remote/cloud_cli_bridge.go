package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const defaultCloudCLIBridgeSocketPath = "/tmp/cmux-cloud-cli.sock"

type cloudCLIResponse struct {
	data []byte
	err  string
}

type cloudCLIBridge struct {
	mu       sync.Mutex
	nextID   uint64
	servers  map[*rpcServer]struct{}
	pending  map[string]chan cloudCLIResponse
	listener net.Listener
}

func newCloudCLIBridge() *cloudCLIBridge {
	return &cloudCLIBridge{
		servers: map[*rpcServer]struct{}{},
		pending: map[string]chan cloudCLIResponse{},
	}
}

func defaultCloudCLIBridgeSocketIfExists() string {
	if info, err := os.Stat(defaultCloudCLIBridgeSocketPath); err == nil && info.Mode()&os.ModeSocket != 0 {
		return defaultCloudCLIBridgeSocketPath
	}
	return ""
}

func (b *cloudCLIBridge) start(ctx context.Context, socketPath string, stderr io.Writer) error {
	if b == nil {
		return nil
	}
	socketPath = stringsTrimSpaceOrDefault(socketPath, defaultCloudCLIBridgeSocketPath)
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return err
	}
	_ = os.Remove(socketPath)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(socketPath, 0o666); err != nil {
		_ = listener.Close()
		_ = os.Remove(socketPath)
		return err
	}
	b.mu.Lock()
	b.listener = listener
	b.mu.Unlock()
	_, _ = fmt.Fprintf(stderr, "cmuxd-remote cloud CLI bridge listening on %s\n", socketPath)
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	go b.acceptLoop(listener, socketPath, stderr)
	return nil
}

func (b *cloudCLIBridge) acceptLoop(listener net.Listener, socketPath string, stderr io.Writer) {
	defer os.Remove(socketPath)
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go b.handleConn(conn)
	}
}

func (b *cloudCLIBridge) register(server *rpcServer) func() {
	if b == nil || server == nil {
		return func() {}
	}
	b.mu.Lock()
	b.servers[server] = struct{}{}
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		delete(b.servers, server)
		b.mu.Unlock()
	}
}

func (b *cloudCLIBridge) handleConn(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(16 * time.Second))
	reader := bufio.NewReaderSize(conn, maxRPCFrameBytes)
	line, oversized, err := readRPCFrame(reader, maxRPCFrameBytes)
	if err != nil {
		return
	}
	if oversized {
		_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"request_too_large","message":"cloud CLI request exceeded maximum size"}}` + "\n"))
		return
	}
	response, err := b.forward(line)
	if err != nil {
		_, _ = conn.Write([]byte(fmt.Sprintf(`{"ok":false,"error":{"code":"cloud_cli_unavailable","message":%q}}`+"\n", err.Error())))
		return
	}
	_, _ = conn.Write(response)
	if len(response) == 0 || response[len(response)-1] != '\n' {
		_, _ = conn.Write([]byte("\n"))
	}
}

func (b *cloudCLIBridge) forward(request []byte) ([]byte, error) {
	server, requestID, responseCh := b.reserveRequest()
	if server == nil {
		return nil, errors.New("no cmux app is attached to this cloud VM")
	}
	if err := server.frameWriter.writeEvent(rpcEvent{
		Event:      "cli.request",
		RequestID:  requestID,
		DataBase64: base64.StdEncoding.EncodeToString(request),
	}); err != nil {
		b.forgetRequest(requestID)
		return nil, err
	}
	select {
	case response := <-responseCh:
		if response.err != "" {
			return nil, errors.New(response.err)
		}
		return response.data, nil
	case <-time.After(15 * time.Second):
		b.forgetRequest(requestID)
		return nil, errors.New("timed out waiting for cmux app response")
	}
}

func (b *cloudCLIBridge) reserveRequest() (*rpcServer, string, chan cloudCLIResponse) {
	b.mu.Lock()
	defer b.mu.Unlock()
	var server *rpcServer
	for candidate := range b.servers {
		server = candidate
		break
	}
	if server == nil {
		return nil, "", nil
	}
	b.nextID++
	requestID := fmt.Sprintf("cli-%d", b.nextID)
	responseCh := make(chan cloudCLIResponse, 1)
	b.pending[requestID] = responseCh
	return server, requestID, responseCh
}

func (b *cloudCLIBridge) forgetRequest(requestID string) {
	b.mu.Lock()
	delete(b.pending, requestID)
	b.mu.Unlock()
}

func (b *cloudCLIBridge) deliverResponse(requestID string, response cloudCLIResponse) bool {
	b.mu.Lock()
	ch := b.pending[requestID]
	if ch != nil {
		delete(b.pending, requestID)
	}
	b.mu.Unlock()
	if ch == nil {
		return false
	}
	ch <- response
	return true
}

func (s *rpcServer) handleCLIResponse(req rpcRequest) rpcResponse {
	if s.cliBridge == nil {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "unavailable", Message: "cloud CLI bridge is not enabled"}}
	}
	requestID, ok := getStringParam(req.Params, "request_id")
	if !ok || requestID == "" {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "invalid_params", Message: "cli.response requires request_id"}}
	}
	responseOK := true
	if raw, exists := req.Params["ok"]; exists {
		if typed, isBool := raw.(bool); isBool {
			responseOK = typed
		}
	}
	var response cloudCLIResponse
	if responseOK {
		dataBase64, ok := getStringParam(req.Params, "data_base64")
		if !ok {
			return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "invalid_params", Message: "cli.response requires data_base64"}}
		}
		data, err := base64.StdEncoding.DecodeString(dataBase64)
		if err != nil {
			return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "invalid_params", Message: "data_base64 must be valid base64"}}
		}
		response.data = data
	} else {
		response.err, _ = getStringParam(req.Params, "error")
		if response.err == "" {
			response.err = "cmux app rejected cloud CLI request"
		}
	}
	if !s.cliBridge.deliverResponse(requestID, response) {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{Code: "not_found", Message: "cloud CLI request not found"}}
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{"delivered": true}}
}

func stringsTrimSpaceOrDefault(value string, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}
