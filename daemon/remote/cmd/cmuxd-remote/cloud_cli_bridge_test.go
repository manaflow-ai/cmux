package main

import (
	"encoding/base64"
	"testing"
)

type testCLIBridgeFrameWriter struct {
	onEvent func(rpcEvent) error
}

func (w testCLIBridgeFrameWriter) writeResponse(rpcResponse) error {
	return nil
}

func (w testCLIBridgeFrameWriter) writeEvent(event rpcEvent) error {
	return w.onEvent(event)
}

func TestCloudCLIBridgeForwardsRequestThroughRPCEvent(t *testing.T) {
	bridge := newCloudCLIBridge()
	server := &rpcServer{cliBridge: bridge}
	server.frameWriter = testCLIBridgeFrameWriter{onEvent: func(event rpcEvent) error {
		if event.Event != "cli.request" {
			t.Fatalf("event = %q, want cli.request", event.Event)
		}
		if event.RequestID == "" {
			t.Fatal("request_id was empty")
		}
		request, err := base64.StdEncoding.DecodeString(event.DataBase64)
		if err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if string(request) != "ping\n" {
			t.Fatalf("request = %q, want ping newline", string(request))
		}
		response := base64.StdEncoding.EncodeToString([]byte("pong\n"))
		resp := server.handleCLIResponse(rpcRequest{
			ID:     "response",
			Method: "cli.response",
			Params: map[string]any{
				"request_id":  event.RequestID,
				"ok":          true,
				"data_base64": response,
			},
		})
		if !resp.OK {
			t.Fatalf("cli.response failed: %+v", resp)
		}
		return nil
	}}
	unregister := bridge.register(server)
	defer unregister()

	response, err := bridge.forward([]byte("ping\n"))
	if err != nil {
		t.Fatalf("forward failed: %v", err)
	}
	if string(response) != "pong\n" {
		t.Fatalf("response = %q, want pong newline", string(response))
	}
}

func TestCloudCLIBridgeSkipsWrongWorkspaceResponses(t *testing.T) {
	bridge := newCloudCLIBridge()
	deniedServer := &rpcServer{cliBridge: bridge}
	acceptedServer := &rpcServer{cliBridge: bridge}

	deniedServer.frameWriter = testCLIBridgeFrameWriter{onEvent: func(event rpcEvent) error {
		response := base64.StdEncoding.EncodeToString([]byte(`{"ok":false,"error":{"code":"remote_cli_workspace_denied","message":"wrong workspace"}}` + "\n"))
		resp := deniedServer.handleCLIResponse(rpcRequest{
			ID:     "denied-response",
			Method: "cli.response",
			Params: map[string]any{
				"request_id":  event.RequestID,
				"ok":          true,
				"data_base64": response,
			},
		})
		if !resp.OK {
			t.Fatalf("denied cli.response failed: %+v", resp)
		}
		return nil
	}}
	acceptedServer.frameWriter = testCLIBridgeFrameWriter{onEvent: func(event rpcEvent) error {
		response := base64.StdEncoding.EncodeToString([]byte(`{"ok":true,"result":{"delivered":true}}` + "\n"))
		resp := acceptedServer.handleCLIResponse(rpcRequest{
			ID:     "accepted-response",
			Method: "cli.response",
			Params: map[string]any{
				"request_id":  event.RequestID,
				"ok":          true,
				"data_base64": response,
			},
		})
		if !resp.OK {
			t.Fatalf("accepted cli.response failed: %+v", resp)
		}
		return nil
	}}

	unregisterDenied := bridge.register(deniedServer)
	defer unregisterDenied()
	unregisterAccepted := bridge.register(acceptedServer)
	defer unregisterAccepted()

	response, err := bridge.forward([]byte("notify\n"))
	if err != nil {
		t.Fatalf("forward failed: %v", err)
	}
	if string(response) != `{"ok":true,"result":{"delivered":true}}`+"\n" {
		t.Fatalf("response = %q, want accepted response", string(response))
	}
}

func TestCloudCLIBridgeRejectsResponseFromUnaddressedServer(t *testing.T) {
	bridge := newCloudCLIBridge()
	addressed := &rpcServer{cliBridge: bridge}
	other := &rpcServer{cliBridge: bridge}
	addressedIDs := make(chan string, 1)
	otherIDs := make(chan string, 1)
	addressed.frameWriter = testCLIBridgeFrameWriter{onEvent: func(event rpcEvent) error {
		addressedIDs <- event.RequestID
		return nil
	}}
	other.frameWriter = testCLIBridgeFrameWriter{onEvent: func(event rpcEvent) error {
		otherIDs <- event.RequestID
		return nil
	}}
	unregisterAddressed := bridge.register(addressed)
	defer unregisterAddressed()
	unregisterOther := bridge.register(other)
	defer unregisterOther()

	type forwardResult struct {
		data []byte
		err  error
	}
	results := make(chan forwardResult, 1)
	go func() {
		data, err := bridge.forward([]byte("ping\n"))
		results <- forwardResult{data: data, err: err}
	}()
	addressedID := <-addressedIDs
	<-otherIDs

	respond := func(server *rpcServer, requestID string, payload string) rpcResponse {
		return server.handleCLIResponse(rpcRequest{
			ID:     "response",
			Method: "cli.response",
			Params: map[string]any{
				"request_id":  requestID,
				"ok":          true,
				"data_base64": base64.StdEncoding.EncodeToString([]byte(payload)),
			},
		})
	}

	if resp := respond(other, addressedID, "spoofed\n"); resp.OK {
		t.Fatalf("cli.response for a request addressed to another client was accepted: %+v", resp)
	}
	if resp := respond(addressed, addressedID, "pong\n"); !resp.OK {
		t.Fatalf("addressed client's cli.response failed: %+v", resp)
	}
	result := <-results
	if result.err != nil {
		t.Fatalf("forward failed: %v", result.err)
	}
	if string(result.data) != "pong\n" {
		t.Fatalf("response = %q, want addressed client's pong", string(result.data))
	}
}
