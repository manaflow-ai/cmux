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
