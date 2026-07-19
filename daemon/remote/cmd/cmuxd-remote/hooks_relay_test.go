package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

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
