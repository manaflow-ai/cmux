package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRemoteHookDescriptorMatchesCanonicalNameAndAlias(t *testing.T) {
	descriptor := remoteHookDescriptor{Name: "rovodev", Aliases: []string{"rovo"}}
	if !remoteHookDescriptorMatches(descriptor, "ROVODEV") {
		t.Fatal("canonical hook name should be case insensitive")
	}
	if !remoteHookDescriptorMatches(descriptor, "rovo") {
		t.Fatal("hook alias should resolve to the catalog entry")
	}
	if remoteHookDescriptorMatches(descriptor, "omp") {
		t.Fatal("unrelated hook name should not match")
	}
}

func TestRemoteHookEnvironmentOmitsRemoteAgentPIDs(t *testing.T) {
	t.Setenv("CMUX_WORKSPACE_ID", "workspace:remote")
	t.Setenv("CMUX_CODEX_PID", "4242")
	t.Setenv("SSH_TTY", "/dev/pts/7")

	environment := remoteHookEnvironment(false)
	if environment["CMUX_WORKSPACE_ID"] != "workspace:remote" {
		t.Fatalf("workspace routing context missing: %#v", environment)
	}
	if _, exists := environment["CMUX_CODEX_PID"]; exists {
		t.Fatal("a remote PID must never be forwarded into the Mac process namespace")
	}
	if environment["SSH_TTY"] != "/dev/pts/7" {
		t.Fatalf("remote terminal routing context missing: %#v", environment)
	}
}

func TestRemoteHookAncestorEnvironmentFiltersUnlistedPIDs(t *testing.T) {
	allowed := map[string]bool{
		"CMUX_WORKSPACE_ID": true,
		"SSH_TTY":           true,
	}
	values := remoteHookEnvironmentEntries(
		[]byte("CMUX_WORKSPACE_ID=workspace:remote\x00CMUX_CODEX_PID=4242\x00SSH_TTY=/dev/pts/7\x00"),
		allowed,
	)
	if values["CMUX_WORKSPACE_ID"] != "workspace:remote" || values["SSH_TTY"] != "/dev/pts/7" {
		t.Fatalf("expected routing values, got %#v", values)
	}
	if _, exists := values["CMUX_CODEX_PID"]; exists {
		t.Fatal("remote PID must not escape ancestor environment filtering")
	}
	if parent := remoteHookParentPID([]byte("Name:\tcmux\nPPid:\t123\n")); parent != 123 {
		t.Fatalf("expected parent PID 123, got %d", parent)
	}
}

func TestRemoteHookSnapshotPayloadAllowsBase64Expansion(t *testing.T) {
	content := make([]byte, remoteHookMaxConfigurationBytes)
	payload, err := encodeRemoteHookSnapshot(remoteHookSnapshot{
		Agent:  "omp",
		Action: "install",
		Entries: []remoteHookSnapshotEntry{{
			Path: "/home/test/.omp/config.json", Kind: "file",
			ContentBase64: base64.StdEncoding.EncodeToString(content), Mode: 0o600,
		}},
	})
	if err != nil {
		t.Fatalf("8 MiB decoded snapshot should fit its transport envelope: %v", err)
	}
	if len(payload) <= remoteHookMaxConfigurationBytes {
		t.Fatalf("test payload did not exercise base64 expansion: %d bytes", len(payload))
	}
}

func TestRemoteHookSnapshotEncodesRequiredSlicesAsEmptyArrays(t *testing.T) {
	entries, err := snapshotRemoteHookPaths(
		[]string{filepath.Join(t.TempDir(), "missing-hooks.json")},
		nil,
	)
	if err != nil {
		t.Fatalf("snapshot missing hook configuration: %v", err)
	}
	payload, err := encodeRemoteHookSnapshot(remoteHookSnapshot{
		Agent: "omp", Action: "install", Entries: entries,
	})
	if err != nil {
		t.Fatalf("encode empty hook snapshot: %v", err)
	}
	var encoded struct {
		Arguments json.RawMessage `json:"arguments"`
		Entries   json.RawMessage `json:"entries"`
	}
	if err := json.Unmarshal(payload, &encoded); err != nil {
		t.Fatalf("decode empty hook snapshot: %v", err)
	}
	if string(encoded.Arguments) != "[]" {
		t.Fatalf("missing hook arguments must encode as an array, got %s", encoded.Arguments)
	}
	if string(encoded.Entries) != "[]" {
		t.Fatalf("missing hook configuration must encode entries as an array, got %s", encoded.Entries)
	}
}

func TestApplyRemoteHookMutationsPreservesUnrelatedFiles(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "hooks.json")
	unrelatedPath := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(configPath, []byte(`{"hooks":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unrelatedPath, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := applyRemoteHookMutations([]remoteHookMutation{{
		Path: configPath, ContentBase64: base64.StdEncoding.EncodeToString([]byte(`{"hooks":{"Stop":[]}}`)), Mode: 0o640,
	}}, []string{configPath}, nil, []remoteHookSnapshotEntry{{
		Path: configPath, Kind: "file", ContentBase64: base64.StdEncoding.EncodeToString([]byte(`{"hooks":{}}`)), Mode: 0o600,
	}})
	if err != nil {
		t.Fatalf("apply mutation: %v", err)
	}
	content, err := os.ReadFile(configPath)
	if err != nil || string(content) != `{"hooks":{"Stop":[]}}` {
		t.Fatalf("unexpected managed config: %q, %v", content, err)
	}
	unrelated, err := os.ReadFile(unrelatedPath)
	if err != nil || string(unrelated) != "keep me" {
		t.Fatalf("unrelated file changed: %q, %v", unrelated, err)
	}
}

func TestApplyRemoteHookMutationsRejectsSiblingPath(t *testing.T) {
	root := t.TempDir()
	managedPath := filepath.Join(root, "hooks.json")
	siblingPath := filepath.Join(root, "settings.json")
	err := applyRemoteHookMutations([]remoteHookMutation{{
		Path: siblingPath, ContentBase64: base64.StdEncoding.EncodeToString([]byte("{}")), Mode: 0o600,
	}}, []string{managedPath}, nil, nil)
	if err == nil {
		t.Fatal("out-of-scope sibling mutation should be rejected")
	}
}

func TestApplyRemoteHookMutationsValidatesPlanBeforeWriting(t *testing.T) {
	root := t.TempDir()
	firstPath := filepath.Join(root, "first.json")
	secondPath := filepath.Join(root, "second.json")
	if err := os.WriteFile(firstPath, []byte("before"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := applyRemoteHookMutations([]remoteHookMutation{
		{
			Path: firstPath, ContentBase64: base64.StdEncoding.EncodeToString([]byte("after")), Mode: 0o600,
		},
		{
			Path: secondPath, ContentBase64: "not-base64", Mode: 0o600,
		},
	}, []string{firstPath, secondPath}, nil, nil)
	if err == nil {
		t.Fatal("invalid later mutation should reject the plan")
	}
	content, readErr := os.ReadFile(firstPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(content) != "before" {
		t.Fatalf("earlier mutation was applied before plan validation: %q", content)
	}
}

func TestApplyRemoteHookMutationsRejectsStaleSnapshot(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(root, "hooks.json")
	if err := os.WriteFile(configPath, []byte("snapshot"), 0o600); err != nil {
		t.Fatal(err)
	}
	expected, err := snapshotRemoteHookPaths([]string{configPath}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, []byte("concurrent edit"), 0o600); err != nil {
		t.Fatal(err)
	}

	err = applyRemoteHookMutations([]remoteHookMutation{{
		Path: configPath, ContentBase64: base64.StdEncoding.EncodeToString([]byte("installer edit")), Mode: 0o600,
	}}, []string{configPath}, nil, expected)
	if err == nil {
		t.Fatal("stale hook plan should be rejected")
	}
	content, readErr := os.ReadFile(configPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(content) != "concurrent edit" {
		t.Fatalf("concurrent hook edit was overwritten: %q", content)
	}
}

func TestSnapshotRemoteHookPathsOnlyTraversesDeclaredRecursiveDirectories(t *testing.T) {
	root := t.TempDir()
	exactDirectory := filepath.Join(root, "exact")
	recursiveDirectory := filepath.Join(root, "recursive")
	if err := os.MkdirAll(exactDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(recursiveDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	exactChild := filepath.Join(exactDirectory, "unmanaged.txt")
	recursiveChild := filepath.Join(recursiveDirectory, "managed.txt")
	if err := os.WriteFile(exactChild, []byte("unmanaged"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(recursiveChild, []byte("managed"), 0o600); err != nil {
		t.Fatal(err)
	}

	entries, err := snapshotRemoteHookPaths(
		[]string{exactDirectory, recursiveDirectory},
		[]string{recursiveDirectory},
	)
	if err != nil {
		t.Fatalf("snapshot hook paths: %v", err)
	}
	seen := make(map[string]bool)
	for _, entry := range entries {
		seen[entry.Path] = true
	}
	if seen[exactChild] {
		t.Fatal("an exact managed directory must not expose undeclared descendants")
	}
	if !seen[recursiveChild] {
		t.Fatal("a recursive managed directory must include its descendants")
	}
}
