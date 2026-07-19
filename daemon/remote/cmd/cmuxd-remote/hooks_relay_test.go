package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net"
	"strings"
	"testing"
)

func TestChunkedHookAppendFailureCancelsTransfer(t *testing.T) {
	sockPath, requests := startFailingHookAppendSocket(t)
	_, err := invokeRemoteHook(
		sockPath,
		[]string{"omp", "session-start"},
		bytes.Repeat([]byte("x"), remoteHookDirectBytes+1),
		func() string { return "" },
	)
	if err == nil {
		t.Fatal("append failure should fail the hook invocation")
	}

	for _, expectedMethod := range []string{"hooks.invoke.begin", "hooks.invoke.append", "hooks.invoke.cancel"} {
		request := receiveRequest(t, requests)
		if request["method"] != expectedMethod {
			t.Fatalf("expected %s, got %v", expectedMethod, request["method"])
		}
		if expectedMethod == "hooks.invoke.cancel" && params(request)["transfer_id"] != "0:00000000-0000-0000-0000-000000000001" {
			t.Fatalf("cancel request lost transfer id: %#v", params(request))
		}
	}
}

func TestHooksEventRelaysPayloadAndRemoteTarget(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("CMUX_WORKSPACE_ID", "remote-workspace")
	t.Setenv("CMUX_SURFACE_ID", "remote-surface")

	payload := `{"session_id":"omp-session","cwd":"/home/alex/project"}`
	code := runCLIWithInput(
		[]string{"--socket", sockPath, "hooks", "omp", "session-start"},
		strings.NewReader(payload),
	)
	if code != 0 {
		t.Fatalf("hooks omp session-start: exit %d", code)
	}

	request := receiveRequest(t, requests)
	if request["method"] != "hooks.invoke" {
		t.Fatalf("expected hooks.invoke, got %v", request["method"])
	}
	requestParams := params(request)
	arguments, ok := requestParams["arguments"].([]any)
	if !ok || len(arguments) != 2 || arguments[0] != "omp" || arguments[1] != "session-start" {
		t.Fatalf("expected hook arguments, got %#v", requestParams["arguments"])
	}
	if requestParams["stdin_base64"] != base64.StdEncoding.EncodeToString([]byte(payload)) {
		t.Fatalf("expected base64 hook payload, got %v", requestParams["stdin_base64"])
	}
	environment, ok := requestParams["environment"].(map[string]any)
	if !ok {
		t.Fatalf("expected environment map, got %T", requestParams["environment"])
	}
	if environment["CMUX_WORKSPACE_ID"] != "remote-workspace" {
		t.Fatalf("expected remote workspace context, got %v", environment["CMUX_WORKSPACE_ID"])
	}
	if environment["CMUX_SURFACE_ID"] != "remote-surface" {
		t.Fatalf("expected remote surface context, got %v", environment["CMUX_SURFACE_ID"])
	}
}

func startFailingHookAppendSocket(t *testing.T) (string, <-chan map[string]any) {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)
	requests := make(chan map[string]any, 4)
	listener, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen for hook relay test: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func(connection net.Conn) {
				defer connection.Close()
				var request map[string]any
				if json.NewDecoder(connection).Decode(&request) != nil {
					return
				}
				requests <- request
				response := map[string]any{"id": request["id"], "ok": true, "result": map[string]any{}}
				switch request["method"] {
				case "hooks.invoke.begin":
					response["result"] = map[string]any{
						"transfer_id": "0:00000000-0000-0000-0000-000000000001",
					}
				case "hooks.invoke.append":
					response = map[string]any{
						"id":    request["id"],
						"ok":    false,
						"error": map[string]any{"code": "append_failed", "message": "test failure"},
					}
				}
				_ = json.NewEncoder(connection).Encode(response)
			}(connection)
		}
	}()

	return sockPath, requests
}
