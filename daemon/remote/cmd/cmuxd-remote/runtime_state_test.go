package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPersistentDaemonServerKeepsPTYAvailableAndFailsRuntimeStateClosedOnCorruption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "slot", "runtime-state.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("create runtime state directory: %v", err)
	}
	if err := os.WriteFile(path, []byte("not-json"), 0o600); err != nil {
		t.Fatalf("write corrupt runtime state: %v", err)
	}
	socketDir, err := os.MkdirTemp("/tmp", "cmuxd-runtime-state-*")
	if err != nil {
		t.Fatalf("create socket directory: %v", err)
	}
	defer os.RemoveAll(socketDir)
	socketPath := filepath.Join(socketDir, "rpc.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer listener.Close()
	acceptingListener := &acceptSignalListener{
		Listener: listener,
		started:  make(chan struct{}),
	}
	var stderr bytes.Buffer
	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifierConfig(
			acceptingListener,
			persistentDaemonFixedTokenVerifier("token"),
			&stderr,
			persistentDaemonServerConfig{runtimeStateFile: path},
		)
	}()
	select {
	case err := <-done:
		t.Fatalf("corrupt optional runtime state stopped persistent daemon: %v", err)
	case <-acceptingListener.started:
	case <-time.After(time.Second):
		t.Fatal("persistent daemon did not begin accepting connections")
	}

	conn, reader, writer := openPersistentTestClient(t, socketPath, "token")
	hello := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     "hello-after-corruption",
		Method: "hello",
		Params: map[string]any{},
	})
	helloResult := requireRuntimeStateResult(t, hello)
	capabilities, _ := helloResult["capabilities"].([]any)
	for _, capability := range capabilities {
		if capability == "runtime.state.v1" {
			t.Fatalf("hello advertised unavailable runtime state: %v", capabilities)
		}
	}
	ping := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     "ping-after-corruption",
		Method: "ping",
		Params: map[string]any{},
	})
	if ok, _ := ping["ok"].(bool); !ok {
		t.Fatalf("persistent daemon ping failed with corrupt runtime state: %v", ping)
	}
	ptyList := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     "pty-list-after-corruption",
		Method: "pty.list",
		Params: map[string]any{},
	})
	if ok, _ := ptyList["ok"].(bool); !ok {
		t.Fatalf("PTY service failed with corrupt runtime state: %v", ptyList)
	}

	runtimeStateRequests := []rpcRequest{
		{ID: "get-after-corruption", Method: "runtime.state.get", Params: map[string]any{}},
		{ID: "subscribe-after-corruption", Method: "runtime.state.subscribe", Params: map[string]any{}},
		{
			ID:     "put-after-corruption",
			Method: "runtime.state.put",
			Params: map[string]any{
				"schema_version": 1,
				"state":          map[string]any{"title": "must-not-overwrite"},
			},
		},
	}
	for _, request := range runtimeStateRequests {
		response := persistentTestRPCCall(t, conn, reader, writer, request)
		if ok, _ := response["ok"].(bool); ok {
			t.Fatalf("%s unexpectedly succeeded with corrupt runtime state: %v", request.Method, response)
		}
		errorObject, _ := response["error"].(map[string]any)
		if errorObject["code"] != "runtime_state_unavailable" {
			t.Fatalf("%s error = %v, want runtime_state_unavailable", request.Method, errorObject)
		}
	}
	_ = conn.Close()
	_ = listener.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("stop persistent daemon: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("persistent daemon did not stop")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read preserved corrupt runtime state: %v", err)
	}
	if string(data) != "not-json" {
		t.Fatalf("corrupt runtime state changed to %q", data)
	}
	if !strings.Contains(stderr.String(), "runtime state") {
		t.Fatalf("missing corrupt runtime state diagnostic: %q", stderr.String())
	}
}

type acceptSignalListener struct {
	net.Listener
	started chan struct{}
	once    sync.Once
}

func (l *acceptSignalListener) Accept() (net.Conn, error) {
	l.once.Do(func() { close(l.started) })
	return l.Listener.Accept()
}

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

func TestPersistRuntimeStateDocumentSyncsParentDirectoryAfterRename(t *testing.T) {
	path := filepath.Join(t.TempDir(), "slot", "runtime-state.json")
	events := []string{}
	fileSystem := &recordingRuntimeStateFileSystem{events: &events}
	document := runtimeStateDocument{
		ProtocolVersion: runtimeStateProtocolVersion,
		SchemaVersion:   1,
		Revision:        1,
		UpdatedAtUnixMS: 1,
		State:           json.RawMessage(`{"title":"durable"}`),
	}

	if err := persistRuntimeStateDocumentWithFileSystem(path, document, fileSystem); err != nil {
		t.Fatalf("persist runtime state: %v", err)
	}
	want := []string{"rename", "open-directory", "sync-directory", "close-directory"}
	if strings.Join(events, ",") != strings.Join(want, ",") {
		t.Fatalf("persistence events = %v, want %v", events, want)
	}
}

type recordingRuntimeStateFileSystem struct {
	events *[]string
}

func (*recordingRuntimeStateFileSystem) MkdirAll(path string, mode os.FileMode) error {
	return os.MkdirAll(path, mode)
}

func (*recordingRuntimeStateFileSystem) CreateTemp(directory string, pattern string) (runtimeStateTemporaryFile, error) {
	return os.CreateTemp(directory, pattern)
}

func (*recordingRuntimeStateFileSystem) Remove(path string) error {
	return os.Remove(path)
}

func (fileSystem *recordingRuntimeStateFileSystem) Rename(oldPath string, newPath string) error {
	if err := os.Rename(oldPath, newPath); err != nil {
		return err
	}
	*fileSystem.events = append(*fileSystem.events, "rename")
	return nil
}

func (fileSystem *recordingRuntimeStateFileSystem) OpenDirectory(path string) (runtimeStateDirectory, error) {
	directory, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	*fileSystem.events = append(*fileSystem.events, "open-directory")
	return &recordingRuntimeStateDirectory{
		File:   directory,
		events: fileSystem.events,
	}, nil
}

type recordingRuntimeStateDirectory struct {
	*os.File
	events *[]string
}

func (directory *recordingRuntimeStateDirectory) Sync() error {
	*directory.events = append(*directory.events, "sync-directory")
	return directory.File.Sync()
}

func (directory *recordingRuntimeStateDirectory) Close() error {
	*directory.events = append(*directory.events, "close-directory")
	return directory.File.Close()
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

func TestRuntimeStateStoreSnapshotDoesNotBlockOnPersistence(t *testing.T) {
	persistenceStarted := make(chan struct{})
	releasePersistence := make(chan struct{})
	var releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(releasePersistence) })
	store := newEmptyRuntimeStateStore("runtime-state.json")
	store.persistDocument = func(string, runtimeStateDocument) error {
		close(persistenceStarted)
		<-releasePersistence
		return nil
	}

	putDone := make(chan error, 1)
	go func() {
		_, err := store.put(1, json.RawMessage(`{"title":"writer"}`), nil)
		putDone <- err
	}()
	select {
	case <-persistenceStarted:
	case <-time.After(time.Second):
		t.Fatal("runtime state persistence did not start")
	}

	snapshotDone := make(chan *runtimeStateDocument, 1)
	go func() { snapshotDone <- store.snapshot() }()
	select {
	case snapshot := <-snapshotDone:
		if snapshot != nil {
			t.Fatalf("snapshot exposed uncommitted runtime state: %+v", snapshot)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("runtime state snapshot blocked on persistence")
	}

	releaseOnce.Do(func() { close(releasePersistence) })
	select {
	case err := <-putDone:
		if err != nil {
			t.Fatalf("put runtime state: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("runtime state put did not finish")
	}
	if snapshot := store.snapshot(); snapshot == nil || snapshot.Revision != 1 {
		t.Fatalf("committed runtime state snapshot = %+v, want revision 1", snapshot)
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
