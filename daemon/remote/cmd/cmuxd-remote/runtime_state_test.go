package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPersistentDaemonRuntimeStateIsSharedRevisionedAndObservable(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "runtime-state-token")
	defer stop()

	observerConn, observerReader, observerWriter := openPersistentTestClient(t, socketPath, "runtime-state-token")
	defer observerConn.Close()
	writerConn, writerReader, writerWriter := openPersistentTestClient(t, socketPath, "runtime-state-token")
	defer writerConn.Close()

	subscribe := persistentTestRPCCall(t, observerConn, observerReader, observerWriter, rpcRequest{
		ID:     "subscribe",
		Method: "runtime.state.subscribe",
		Params: map[string]any{},
	})
	subscribeResult := requireRuntimeStateResult(t, subscribe)
	if present, _ := subscribeResult["present"].(bool); present {
		t.Fatalf("initial runtime state unexpectedly present: %v", subscribe)
	}
	if revision, _ := subscribeResult["revision"].(float64); revision != 0 {
		t.Fatalf("initial revision = %v, want 0", revision)
	}

	put := persistentTestRPCCall(t, writerConn, writerReader, writerWriter, rpcRequest{
		ID:     "put",
		Method: "runtime.state.put",
		Params: map[string]any{
			"schema_version":    17,
			"expected_revision": 0,
			"state": map[string]any{
				"title": "cold attach",
				"cwd":   "/srv/project",
				"layout": map[string]any{
					"type": "pane",
				},
			},
		},
	})
	putResult := requireRuntimeStateResult(t, put)
	if revision, _ := putResult["revision"].(float64); revision != 1 {
		t.Fatalf("put revision = %v, want 1", revision)
	}

	event := readPersistentTestEvent(t, observerConn, observerReader, func(frame map[string]any) bool {
		return frame["event"] == "runtime.state.changed"
	})
	eventResult, _ := event["result"].(map[string]any)
	if revision, _ := eventResult["revision"].(float64); revision != 1 {
		t.Fatalf("event revision = %v, want 1; event=%v", revision, event)
	}
	state, _ := eventResult["state"].(map[string]any)
	if state["title"] != "cold attach" || state["cwd"] != "/srv/project" {
		t.Fatalf("event state = %v", state)
	}

	get := persistentTestRPCCall(t, observerConn, observerReader, observerWriter, rpcRequest{
		ID:     "get",
		Method: "runtime.state.get",
		Params: map[string]any{},
	})
	getResult := requireRuntimeStateResult(t, get)
	if getResult["protocol_version"] != float64(runtimeStateProtocolVersion) ||
		getResult["schema_version"] != float64(17) ||
		getResult["revision"] != float64(1) {
		t.Fatalf("unexpected get result: %v", getResult)
	}
	if _, ok := getResult["pty_sessions"].([]any); !ok {
		t.Fatalf("get result missing PTY session manifest: %v", getResult)
	}

	conflict := persistentTestRPCCall(t, writerConn, writerReader, writerWriter, rpcRequest{
		ID:     "conflict",
		Method: "runtime.state.put",
		Params: map[string]any{
			"schema_version":    17,
			"expected_revision": 0,
			"state":             map[string]any{"title": "stale writer"},
		},
	})
	if ok, _ := conflict["ok"].(bool); ok {
		t.Fatalf("stale put unexpectedly succeeded: %v", conflict)
	}
	errorObject, _ := conflict["error"].(map[string]any)
	if errorObject["code"] != "revision_conflict" {
		t.Fatalf("stale put error = %v, want revision_conflict", errorObject)
	}
}

func TestRuntimeStateStorePersistsAcrossRepositoryRecreation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "slot", "runtime-state.json")
	store, err := newRuntimeStateStore(path)
	if err != nil {
		t.Fatalf("create runtime state store: %v", err)
	}
	document, err := store.put(9, json.RawMessage(`{"workspace":{"title":"persisted"}}`), nil)
	if err != nil {
		t.Fatalf("put runtime state: %v", err)
	}
	if document.Revision != 1 {
		t.Fatalf("revision = %d, want 1", document.Revision)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat runtime state: %v", err)
	}
	if permissions := info.Mode().Perm(); permissions != 0o600 {
		t.Fatalf("runtime state permissions = %o, want 600", permissions)
	}

	reloaded, err := newRuntimeStateStore(path)
	if err != nil {
		t.Fatalf("reload runtime state store: %v", err)
	}
	snapshot := reloaded.snapshot()
	if snapshot == nil {
		t.Fatal("reloaded runtime state is nil")
	}
	if snapshot.ProtocolVersion != runtimeStateProtocolVersion || snapshot.SchemaVersion != 9 || snapshot.Revision != 1 {
		t.Fatalf("unexpected reloaded document: %+v", snapshot)
	}
	var state map[string]any
	if err := json.Unmarshal(snapshot.State, &state); err != nil {
		t.Fatalf("decode reloaded state: %v", err)
	}
	workspace, _ := state["workspace"].(map[string]any)
	if workspace["title"] != "persisted" {
		t.Fatalf("reloaded state = %v", state)
	}
	next, err := reloaded.put(9, snapshot.State, nil)
	if err != nil {
		t.Fatalf("put reloaded runtime state: %v", err)
	}
	if next.Revision != 2 {
		t.Fatalf("reloaded revision = %d, want 2", next.Revision)
	}
}

func TestRuntimeStateStoreRejectsOversizedPersistedPayload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "slot", "runtime-state.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("create runtime state directory: %v", err)
	}
	document := runtimeStateDocument{
		ProtocolVersion: runtimeStateProtocolVersion,
		SchemaVersion:   1,
		Revision:        1,
		UpdatedAtUnixMS: 1,
		State: json.RawMessage(
			`{"blob":"` + strings.Repeat("x", maxRuntimeStateBytes) + `"}`,
		),
	}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("encode oversized runtime state: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write oversized runtime state: %v", err)
	}

	if _, err := newRuntimeStateStore(path); err == nil {
		t.Fatal("oversized persisted runtime state unexpectedly loaded")
	}
}

func TestRuntimeStatePutDoesNotExposePersistencePath(t *testing.T) {
	parentPath := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(parentPath, []byte("occupied"), 0o600); err != nil {
		t.Fatalf("create blocking file: %v", err)
	}
	statePath := filepath.Join(parentPath, "runtime-state.json")
	store := &runtimeStateStore{
		filePath:    statePath,
		subscribers: map[uint64]*runtimeStateSubscriber{},
	}
	server := &rpcServer{runtimeState: store}
	response := server.handleRuntimeStatePut(rpcRequest{
		ID:     "put",
		Method: "runtime.state.put",
		Params: map[string]any{
			"schema_version": 1,
			"state":          map[string]any{"title": "private"},
		},
	})
	if response.Error == nil || response.Error.Code != "state_write_failed" {
		t.Fatalf("runtime state put error = %#v, want state_write_failed", response.Error)
	}
	if strings.Contains(response.Error.Message, parentPath) {
		t.Fatalf("runtime state put exposed persistence path: %q", response.Error.Message)
	}
}

func TestRuntimeStateStorePutDoesNotBlockOnSlowSubscriber(t *testing.T) {
	store, err := newRuntimeStateStore("")
	if err != nil {
		t.Fatalf("create runtime state store: %v", err)
	}

	subscriberStarted := make(chan struct{})
	releaseSubscriber := make(chan struct{})
	defer close(releaseSubscriber)
	subscriberID, _ := store.subscribe(func(runtimeStateDocument) {
		close(subscriberStarted)
		<-releaseSubscriber
	})
	defer store.unsubscribe(subscriberID)

	putDone := make(chan error, 1)
	go func() {
		_, err := store.put(1, json.RawMessage(`{"title":"writer"}`), nil)
		putDone <- err
	}()

	select {
	case <-subscriberStarted:
	case <-time.After(time.Second):
		t.Fatal("runtime state subscriber was not invoked")
	}
	select {
	case err := <-putDone:
		if err != nil {
			t.Fatalf("put runtime state: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("runtime state put blocked on a slow subscriber")
	}
}

func requireRuntimeStateResult(t *testing.T, frame map[string]any) map[string]any {
	t.Helper()
	if ok, _ := frame["ok"].(bool); !ok {
		t.Fatalf("runtime state RPC failed: %v", frame)
	}
	result, ok := frame["result"].(map[string]any)
	if !ok {
		t.Fatalf("runtime state RPC missing result: %v", frame)
	}
	return result
}
