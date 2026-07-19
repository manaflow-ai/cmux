package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	remoteHookTimeout               = 130 * time.Second
	remoteHookCleanupTimeout        = 10 * time.Second
	remoteHookChunkBytes            = 6 * 1024
	remoteHookDirectBytes           = 3 * 1024
	remoteHookMaxEventInput         = 8 * 1024 * 1024
	remoteHookMaxConfigurationBytes = 8 * 1024 * 1024
	remoteHookMaxBridgePayload      = 16 * 1024 * 1024
)

var remoteHookRoutingEnvironmentKeys = []string{
	"CMUX_WORKSPACE_ID",
	"CMUX_SURFACE_ID",
	"CMUX_AGENT_LAUNCH_KIND",
	"CMUX_AGENT_LAUNCH_EXECUTABLE",
	"CMUX_AGENT_LAUNCH_ARGV_B64",
	"CMUX_AGENT_LAUNCH_CWD",
	"CMUX_REMOTE_PTY_SESSION_ID",
	"CMUX_SSH_PTY_SESSION_ID",
	"CMUX_CLI_TTY_NAME",
	"CMUX_TTY_NAME",
	"TTY",
	"SSH_TTY",
	"PWD",
}

var remoteHookFilesystemEnvironmentKeys = []string{
	"CMUX_BUNDLED_CLI_PATH",
	"HOME",
	"PWD",
	"CODEX_HOME",
	"GROK_HOME",
	"OPENCODE_CONFIG_DIR",
	"PI_CODING_AGENT_DIR",
	"PI_CONFIG_DIR",
	"CAMPFIRE_CODING_AGENT_DIR",
	"KIRO_HOME",
	"HERMES_HOME",
	"COPILOT_HOME",
	"CODEBUDDY_CONFIG_DIR",
	"QODER_CONFIG_DIR",
	"KIMI_SHARE_DIR",
	"KIMI_CODE_HOME",
}

type remoteHookInvocationResult struct {
	StdoutBase64 string `json:"stdout_base64"`
	StderrBase64 string `json:"stderr_base64"`
	ExitCode     int    `json:"exit_code"`
}

type remoteHookDescriptor struct {
	Name                     string   `json:"name"`
	Aliases                  []string `json:"aliases"`
	BinaryName               string   `json:"binary_name"`
	ConfigDirectory          string   `json:"config_directory"`
	InstallWhenConfigMissing bool     `json:"install_when_config_missing"`
	SnapshotPaths            []string `json:"snapshot_paths"`
	RecursivePaths           []string `json:"recursive_paths"`
}

type remoteHookSnapshot struct {
	Agent     string                    `json:"agent"`
	Action    string                    `json:"action"`
	Arguments []string                  `json:"arguments"`
	Entries   []remoteHookSnapshotEntry `json:"entries"`
}

type remoteHookSnapshotEntry struct {
	Path          string `json:"path"`
	Kind          string `json:"kind"`
	ContentBase64 string `json:"content_base64,omitempty"`
	Mode          uint32 `json:"mode"`
}

type remoteHookPlan struct {
	StdoutBase64 string               `json:"stdout_base64"`
	StderrBase64 string               `json:"stderr_base64"`
	ExitCode     int                  `json:"exit_code"`
	Mutations    []remoteHookMutation `json:"mutations"`
}

type remoteHookMutation struct {
	Path          string `json:"path"`
	Delete        bool   `json:"delete,omitempty"`
	ContentBase64 string `json:"content_base64,omitempty"`
	Mode          uint32 `json:"mode,omitempty"`
}

type preparedRemoteHookMutation struct {
	path          string
	delete        bool
	data          []byte
	mode          os.FileMode
	temporaryPath string
}

type remoteHookFileState struct {
	path    string
	existed bool
	data    []byte
	mode    os.FileMode
}

func runHooksRelay(socketPath string, args []string, input io.Reader, refreshAddr func() string) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprintln(os.Stdout, "Usage: cmux hooks <setup|uninstall|agent> [args...]")
		return 0
	}

	switch strings.ToLower(args[0]) {
	case "setup":
		return runRemoteHookSetup(socketPath, args[1:], slicesContain(args[1:], "--uninstall"), refreshAddr)
	case "uninstall":
		return runRemoteHookSetup(socketPath, args[1:], true, refreshAddr)
	case "feed", "claude":
		stdin, err := readRemoteHookStdin(input)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux hooks: %v\n", err)
			return 1
		}
		return relayRemoteHookInvocation(socketPath, args, stdin, refreshAddr)
	}

	if len(args) >= 2 {
		action := strings.ToLower(args[1])
		if action == "install" || action == "uninstall" {
			descriptor, err := describeRemoteHook(socketPath, args[0], refreshAddr)
			if err != nil {
				fmt.Fprintf(os.Stderr, "cmux hooks: %v\n", err)
				return 1
			}
			return configureRemoteHook(socketPath, descriptor, action, args[2:], refreshAddr)
		}
	}
	stdin, err := readRemoteHookStdin(input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks: %v\n", err)
		return 1
	}
	return relayRemoteHookInvocation(socketPath, args, stdin, refreshAddr)
}

func runRemoteHookSetup(socketPath string, args []string, uninstall bool, refreshAddr func() string) int {
	descriptors, err := catalogRemoteHooks(socketPath, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks: %v\n", err)
		return 1
	}
	filter, err := remoteHookSetupFilter(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks: %v\n", err)
		return 2
	}
	if filter != "" {
		matched := descriptors[:0]
		for _, descriptor := range descriptors {
			if remoteHookDescriptorMatches(descriptor, filter) {
				matched = append(matched, descriptor)
			}
		}
		if len(matched) == 0 {
			fmt.Fprintf(os.Stderr, "cmux hooks: unknown hooks target %q\n", filter)
			return 2
		}
		descriptors = matched
	}

	action := "install"
	commandName := "setup"
	progressVerb := "installing"
	completedVerb := "installed"
	if uninstall {
		action = "uninstall"
		commandName = "uninstall"
		progressVerb = "uninstalling"
		completedVerb = "uninstalled"
	}
	fmt.Fprintf(os.Stdout, "cmux hooks %s: %s remote agent hooks\n\n", commandName, progressVerb)
	completed := 0
	skipped := 0
	for _, descriptor := range descriptors {
		if !uninstall {
			if !descriptor.InstallWhenConfigMissing && !remoteHookPathExists(descriptor.ConfigDirectory) {
				fmt.Fprintf(os.Stdout, "  %s: skipped (config dir not found)\n", descriptor.Name)
				skipped++
				continue
			}
			if _, err := exec.LookPath(descriptor.BinaryName); err != nil {
				fmt.Fprintf(os.Stdout, "  %s: skipped (binary not found on PATH)\n", descriptor.Name)
				skipped++
				continue
			}
		}
		fmt.Fprintf(os.Stdout, "  %s:\n", descriptor.Name)
		if code := configureRemoteHook(socketPath, descriptor, action, nil, refreshAddr); code != 0 {
			return code
		}
		completed++
		fmt.Fprintln(os.Stdout)
	}
	fmt.Fprintf(os.Stdout, "Done: %d %s, %d skipped\n", completed, completedVerb, skipped)
	return 0
}

func remoteHookSetupFilter(args []string) (string, error) {
	var filter string
	for index := 0; index < len(args); index++ {
		switch args[index] {
		case "--yes", "-y", "--uninstall":
			continue
		case "--agent":
			if index+1 >= len(args) {
				return "", errors.New("--agent requires a name")
			}
			index++
			if filter != "" && !strings.EqualFold(filter, args[index]) {
				return "", errors.New("conflicting hooks targets")
			}
			filter = args[index]
		default:
			if strings.HasPrefix(args[index], "-") {
				return "", fmt.Errorf("unknown option %q", args[index])
			}
			if filter != "" && !strings.EqualFold(filter, args[index]) {
				return "", errors.New("too many hooks targets")
			}
			filter = args[index]
		}
	}
	return filter, nil
}

func slicesContain(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

func remoteHookDescriptorMatches(descriptor remoteHookDescriptor, candidate string) bool {
	if strings.EqualFold(descriptor.Name, candidate) {
		return true
	}
	for _, alias := range descriptor.Aliases {
		if strings.EqualFold(alias, candidate) {
			return true
		}
	}
	return false
}

func remoteHookPathExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func catalogRemoteHooks(socketPath string, refreshAddr func() string) ([]remoteHookDescriptor, error) {
	result, err := invokeRemoteHook(socketPath, []string{"__remote-catalog"}, nil, refreshAddr)
	if err != nil {
		return nil, err
	}
	if result.ExitCode != 0 {
		return nil, remoteHookInvocationError(result)
	}
	stdout, err := base64.StdEncoding.DecodeString(result.StdoutBase64)
	if err != nil {
		return nil, fmt.Errorf("invalid catalog response: %w", err)
	}
	var descriptors []remoteHookDescriptor
	if err := json.Unmarshal(stdout, &descriptors); err != nil {
		return nil, fmt.Errorf("invalid catalog response: %w", err)
	}
	return descriptors, nil
}

func describeRemoteHook(socketPath, agent string, refreshAddr func() string) (remoteHookDescriptor, error) {
	result, err := invokeRemoteHook(socketPath, []string{"__remote-describe", agent}, nil, refreshAddr)
	if err != nil {
		return remoteHookDescriptor{}, err
	}
	if result.ExitCode != 0 {
		return remoteHookDescriptor{}, remoteHookInvocationError(result)
	}
	stdout, err := base64.StdEncoding.DecodeString(result.StdoutBase64)
	if err != nil {
		return remoteHookDescriptor{}, fmt.Errorf("invalid descriptor response: %w", err)
	}
	var descriptor remoteHookDescriptor
	if err := json.Unmarshal(stdout, &descriptor); err != nil {
		return remoteHookDescriptor{}, fmt.Errorf("invalid descriptor response: %w", err)
	}
	return descriptor, nil
}

func configureRemoteHook(socketPath string, descriptor remoteHookDescriptor, action string, arguments []string, refreshAddr func() string) int {
	entries, err := snapshotRemoteHookPaths(descriptor.SnapshotPaths, descriptor.RecursivePaths)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks %s: %v\n", descriptor.Name, err)
		return 1
	}
	payload, err := encodeRemoteHookSnapshot(remoteHookSnapshot{
		Agent: descriptor.Name, Action: action, Arguments: arguments, Entries: entries,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks %s: %v\n", descriptor.Name, err)
		return 1
	}
	result, err := invokeRemoteHook(socketPath, []string{"__remote-configure"}, payload, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks %s: %v\n", descriptor.Name, err)
		return 1
	}
	if result.ExitCode != 0 {
		writeRemoteHookOutput(result.StdoutBase64, os.Stdout)
		writeRemoteHookOutput(result.StderrBase64, os.Stderr)
		return result.ExitCode
	}
	planJSON, err := base64.StdEncoding.DecodeString(result.StdoutBase64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks %s: invalid install plan\n", descriptor.Name)
		return 1
	}
	var plan remoteHookPlan
	if err := json.Unmarshal(planJSON, &plan); err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks %s: invalid install plan: %v\n", descriptor.Name, err)
		return 1
	}
	if plan.ExitCode != 0 {
		writeRemoteHookOutput(plan.StdoutBase64, os.Stdout)
		writeRemoteHookOutput(plan.StderrBase64, os.Stderr)
		return plan.ExitCode
	}
	if err := applyRemoteHookMutations(
		plan.Mutations,
		descriptor.SnapshotPaths,
		descriptor.RecursivePaths,
		entries,
	); err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks %s: %v\n", descriptor.Name, err)
		return 1
	}
	writeRemoteHookOutput(plan.StdoutBase64, os.Stdout)
	writeRemoteHookOutput(plan.StderrBase64, os.Stderr)
	return 0
}

func encodeRemoteHookSnapshot(snapshot remoteHookSnapshot) ([]byte, error) {
	payload, err := json.Marshal(snapshot)
	if err != nil {
		return nil, err
	}
	if len(payload) > remoteHookMaxBridgePayload {
		return nil, errors.New("encoded hook configuration snapshot exceeds 16 MiB relay limit")
	}
	return payload, nil
}

func readRemoteHookStdin(input io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(input, remoteHookMaxEventInput+1))
	if err != nil {
		return nil, err
	}
	if len(data) > remoteHookMaxEventInput {
		return nil, errors.New("hook payload exceeds 8 MiB relay limit")
	}
	return data, nil
}

func relayRemoteHookInvocation(socketPath string, arguments []string, stdin []byte, refreshAddr func() string) int {
	result, err := invokeRemoteHook(socketPath, arguments, stdin, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux hooks: %v\n", err)
		return 1
	}
	writeRemoteHookOutput(result.StdoutBase64, os.Stdout)
	writeRemoteHookOutput(result.StderrBase64, os.Stderr)
	return result.ExitCode
}

func invokeRemoteHook(socketPath string, arguments []string, stdin []byte, refreshAddr func() string) (remoteHookInvocationResult, error) {
	isFilesystemBridge := len(arguments) > 0 && strings.HasPrefix(arguments[0], "__remote-")
	environment := remoteHookEnvironment(isFilesystemBridge)
	params := map[string]any{
		"arguments":   arguments,
		"environment": environment,
	}
	if workspaceID := environment["CMUX_WORKSPACE_ID"]; workspaceID != "" {
		params["workspace_id"] = workspaceID
	}
	if surfaceID := environment["CMUX_SURFACE_ID"]; surfaceID != "" {
		params["surface_id"] = surfaceID
	}
	if len(stdin) <= remoteHookDirectBytes {
		params["stdin_base64"] = base64.StdEncoding.EncodeToString(stdin)
		response, err := socketRoundTripV2WithTimeout(socketPath, "hooks.invoke", params, refreshAddr, remoteHookTimeout)
		return decodeRemoteHookInvocation(response, err)
	}

	response, err := socketRoundTripV2WithTimeout(socketPath, "hooks.invoke.begin", params, refreshAddr, remoteHookTimeout)
	if err != nil {
		return remoteHookInvocationResult{}, err
	}
	var begin struct {
		TransferID string `json:"transfer_id"`
	}
	if err := json.Unmarshal([]byte(response), &begin); err != nil || begin.TransferID == "" {
		return remoteHookInvocationResult{}, errors.New("invalid hook transfer response")
	}
	cancelPending := true
	defer func() {
		if cancelPending {
			_, _ = socketRoundTripV2WithTimeout(socketPath, "hooks.invoke.cancel", map[string]any{
				"transfer_id": begin.TransferID,
			}, refreshAddr, remoteHookCleanupTimeout)
		}
	}()
	for offset := 0; offset < len(stdin); offset += remoteHookChunkBytes {
		end := min(offset+remoteHookChunkBytes, len(stdin))
		chunkParams := map[string]any{
			"transfer_id":  begin.TransferID,
			"chunk_base64": base64.StdEncoding.EncodeToString(stdin[offset:end]),
		}
		if _, err := socketRoundTripV2WithTimeout(socketPath, "hooks.invoke.append", chunkParams, refreshAddr, remoteHookTimeout); err != nil {
			return remoteHookInvocationResult{}, err
		}
	}
	response, err = socketRoundTripV2WithTimeout(socketPath, "hooks.invoke.execute", map[string]any{
		"transfer_id": begin.TransferID,
	}, refreshAddr, remoteHookTimeout)
	if err == nil {
		cancelPending = false
	}
	return decodeRemoteHookInvocation(response, err)
}

func decodeRemoteHookInvocation(response string, err error) (remoteHookInvocationResult, error) {
	if err != nil {
		return remoteHookInvocationResult{}, err
	}
	var result remoteHookInvocationResult
	if err := json.Unmarshal([]byte(response), &result); err != nil {
		return remoteHookInvocationResult{}, fmt.Errorf("invalid hook response: %w", err)
	}
	return result, nil
}

func remoteHookInvocationError(result remoteHookInvocationResult) error {
	stderr, _ := base64.StdEncoding.DecodeString(result.StderrBase64)
	message := strings.TrimSpace(string(stderr))
	if message == "" {
		message = fmt.Sprintf("hook bridge exited %d", result.ExitCode)
	}
	return errors.New(message)
}

func remoteHookEnvironment(filesystemBridge bool) map[string]string {
	environment := make(map[string]string)
	totalBytes := 0
	ancestorEnvironment := map[string]string{}
	if !filesystemBridge && (os.Getenv("CMUX_WORKSPACE_ID") == "" || os.Getenv("CMUX_SURFACE_ID") == "") {
		ancestorEnvironment = remoteHookAncestorEnvironment()
	}
	keys := remoteHookRoutingEnvironmentKeys
	if filesystemBridge {
		keys = remoteHookFilesystemEnvironmentKeys
	}
	for _, key := range keys {
		value := os.Getenv(key)
		if value == "" {
			value = ancestorEnvironment[key]
		}
		if value != "" && len(value) <= 2*1024 && totalBytes+len(key)+len(value) <= 4*1024 {
			environment[key] = value
			totalBytes += len(key) + len(value)
		}
	}
	return environment
}

func remoteHookAncestorEnvironment() map[string]string {
	// Some agents strip CMUX_* only from hook children. Resolve routing values
	// locally from their ancestor chain; never export a remote PID to macOS.
	allowed := make(map[string]bool, len(remoteHookRoutingEnvironmentKeys))
	for _, key := range remoteHookRoutingEnvironmentKeys {
		if strings.HasPrefix(key, "CMUX_") || key == "TTY" || key == "SSH_TTY" {
			allowed[key] = true
		}
	}
	result := make(map[string]string)
	pid := os.Getppid()
	for depth := 0; depth < 16 && pid > 1; depth++ {
		data, err := os.ReadFile(filepath.Join("/proc", fmt.Sprint(pid), "environ"))
		if err != nil {
			break
		}
		for key, value := range remoteHookEnvironmentEntries(data, allowed) {
			if result[key] == "" {
				result[key] = value
			}
		}
		status, err := os.ReadFile(filepath.Join("/proc", fmt.Sprint(pid), "status"))
		if err != nil {
			break
		}
		pid = remoteHookParentPID(status)
	}
	return result
}

func remoteHookEnvironmentEntries(data []byte, allowed map[string]bool) map[string]string {
	result := make(map[string]string)
	for _, entry := range strings.Split(string(data), "\x00") {
		key, value, found := strings.Cut(entry, "=")
		if found && allowed[key] && value != "" {
			result[key] = value
		}
	}
	return result
}

func remoteHookParentPID(status []byte) int {
	for _, line := range strings.Split(string(status), "\n") {
		if value, found := strings.CutPrefix(line, "PPid:"); found {
			pid, _ := strconv.Atoi(strings.TrimSpace(value))
			return pid
		}
	}
	return 0
}

func writeRemoteHookOutput(encoded string, destination *os.File) {
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err == nil && len(data) > 0 {
		_, _ = destination.Write(data)
	}
}

func snapshotRemoteHookPaths(paths, recursivePaths []string) ([]remoteHookSnapshotEntry, error) {
	entries := make([]remoteHookSnapshotEntry, 0)
	total := 0
	for _, root := range paths {
		root = filepath.Clean(root)
		info, err := os.Lstat(root)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("refusing symlinked hook config path %s", root)
		}
		if !info.IsDir() {
			entry, size, err := snapshotRemoteHookFile(root, info)
			if err != nil {
				return nil, err
			}
			total += size
			if total > remoteHookMaxConfigurationBytes {
				return nil, errors.New("hook configuration exceeds 8 MiB relay limit")
			}
			entries = append(entries, entry)
			continue
		}
		entries = append(entries, remoteHookSnapshotEntry{Path: root, Kind: "directory", Mode: uint32(info.Mode().Perm())})
		if !remoteHookPathIsRecursive(root, recursivePaths) {
			continue
		}
		err = filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if path == root {
				return nil
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("refusing symlinked hook config path %s", path)
			}
			if entry.IsDir() {
				entries = append(entries, remoteHookSnapshotEntry{Path: path, Kind: "directory", Mode: uint32(info.Mode().Perm())})
				return nil
			}
			fileEntry, size, err := snapshotRemoteHookFile(path, info)
			if err != nil {
				return err
			}
			total += size
			if total > remoteHookMaxConfigurationBytes {
				return errors.New("hook configuration exceeds 8 MiB relay limit")
			}
			entries = append(entries, fileEntry)
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	return entries, nil
}

func remoteHookPathIsRecursive(path string, recursivePaths []string) bool {
	path = filepath.Clean(path)
	for _, recursivePath := range recursivePaths {
		if path == filepath.Clean(recursivePath) {
			return true
		}
	}
	return false
}

func snapshotRemoteHookFile(path string, info os.FileInfo) (remoteHookSnapshotEntry, int, error) {
	if !info.Mode().IsRegular() {
		return remoteHookSnapshotEntry{}, 0, fmt.Errorf("unsupported hook config file type at %s", path)
	}
	if info.Size() > remoteHookMaxConfigurationBytes {
		return remoteHookSnapshotEntry{}, 0, fmt.Errorf("hook configuration file exceeds 8 MiB: %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return remoteHookSnapshotEntry{}, 0, err
	}
	return remoteHookSnapshotEntry{
		Path: path, Kind: "file", ContentBase64: base64.StdEncoding.EncodeToString(data), Mode: uint32(info.Mode().Perm()),
	}, len(data), nil
}

func applyRemoteHookMutations(
	mutations []remoteHookMutation,
	allowedPaths, recursivePaths []string,
	expectedEntries []remoteHookSnapshotEntry,
) error {
	prepared, err := prepareRemoteHookMutations(mutations, allowedPaths, recursivePaths)
	if err != nil {
		return err
	}
	expectedFiles, err := expectedRemoteHookFiles(expectedEntries)
	if err != nil {
		return err
	}
	previous, err := captureRemoteHookFileStates(prepared, expectedFiles)
	if err != nil {
		return err
	}
	createdDirectories, err := stageRemoteHookMutations(prepared)
	if err != nil {
		cleanupRemoteHookStaging(prepared, createdDirectories)
		return err
	}

	applied := 0
	for index := range prepared {
		mutation := &prepared[index]
		if mutation.delete {
			err = os.Remove(mutation.path)
			if errors.Is(err, os.ErrNotExist) {
				err = nil
			}
		} else {
			err = os.Rename(mutation.temporaryPath, mutation.path)
			if err == nil {
				mutation.temporaryPath = ""
			}
		}
		if err != nil {
			rollbackErr := rollbackRemoteHookMutations(previous[:applied])
			cleanupRemoteHookStaging(prepared, createdDirectories)
			if rollbackErr != nil {
				return errors.Join(err, fmt.Errorf("hook mutation rollback failed: %w", rollbackErr))
			}
			return err
		}
		applied++
	}
	cleanupRemoteHookTemporaryFiles(prepared)
	return nil
}

func prepareRemoteHookMutations(
	mutations []remoteHookMutation,
	allowedPaths, recursivePaths []string,
) ([]preparedRemoteHookMutation, error) {
	if len(mutations) > 4096 {
		return nil, errors.New("installer returned too many hook mutations")
	}
	prepared := make([]preparedRemoteHookMutation, 0, len(mutations))
	seen := make(map[string]bool, len(mutations))
	totalBytes := 0
	for _, mutation := range mutations {
		path := filepath.Clean(mutation.Path)
		if !remoteHookMutationAllowed(path, allowedPaths, recursivePaths) {
			return nil, fmt.Errorf("installer returned an out-of-scope path: %s", path)
		}
		if seen[path] {
			return nil, fmt.Errorf("installer returned duplicate hook mutation path: %s", path)
		}
		seen[path] = true
		preparedMutation := preparedRemoteHookMutation{path: path, delete: mutation.Delete}
		if !mutation.Delete {
			data, err := base64.StdEncoding.DecodeString(mutation.ContentBase64)
			if err != nil {
				return nil, fmt.Errorf("invalid content for %s", path)
			}
			totalBytes += len(data)
			if totalBytes > remoteHookMaxConfigurationBytes {
				return nil, errors.New("hook mutation plan exceeds 8 MiB relay limit")
			}
			preparedMutation.data = data
			preparedMutation.mode = os.FileMode(mutation.Mode).Perm()
			if preparedMutation.mode == 0 {
				preparedMutation.mode = 0o600
			}
		}
		prepared = append(prepared, preparedMutation)
	}
	return prepared, nil
}

func expectedRemoteHookFiles(entries []remoteHookSnapshotEntry) (map[string]remoteHookSnapshotEntry, error) {
	files := make(map[string]remoteHookSnapshotEntry)
	seen := make(map[string]bool, len(entries))
	for _, entry := range entries {
		path := filepath.Clean(entry.Path)
		if seen[path] {
			return nil, fmt.Errorf("duplicate hook snapshot path: %s", path)
		}
		seen[path] = true
		if entry.Kind == "file" {
			files[path] = entry
		}
	}
	return files, nil
}

func captureRemoteHookFileStates(
	mutations []preparedRemoteHookMutation,
	expectedFiles map[string]remoteHookSnapshotEntry,
) ([]remoteHookFileState, error) {
	states := make([]remoteHookFileState, 0, len(mutations))
	totalBytes := 0
	for _, mutation := range mutations {
		state := remoteHookFileState{path: mutation.path}
		expected, expectedFile := expectedFiles[mutation.path]
		info, err := os.Lstat(mutation.path)
		if errors.Is(err, os.ErrNotExist) {
			if expectedFile {
				return nil, remoteHookConfigurationConflict(mutation.path)
			}
			states = append(states, state)
			continue
		}
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("unsupported existing hook config file type at %s", mutation.path)
		}
		if !expectedFile {
			return nil, remoteHookConfigurationConflict(mutation.path)
		}
		state.existed = true
		state.mode = info.Mode().Perm()
		state.data, err = os.ReadFile(mutation.path)
		if err != nil {
			return nil, err
		}
		totalBytes += len(state.data)
		if totalBytes > remoteHookMaxConfigurationBytes {
			return nil, errors.New("existing hook configuration exceeds 8 MiB rollback limit")
		}
		expectedData, err := base64.StdEncoding.DecodeString(expected.ContentBase64)
		if err != nil {
			return nil, fmt.Errorf("invalid expected content for %s", mutation.path)
		}
		if !bytes.Equal(state.data, expectedData) || uint32(state.mode) != expected.Mode {
			return nil, remoteHookConfigurationConflict(mutation.path)
		}
		states = append(states, state)
	}
	return states, nil
}

func remoteHookConfigurationConflict(path string) error {
	return fmt.Errorf("hook configuration changed while installer was running; retry: %s", path)
}

func stageRemoteHookMutations(mutations []preparedRemoteHookMutation) ([]string, error) {
	var createdDirectories []string
	for index := range mutations {
		mutation := &mutations[index]
		if mutation.delete {
			continue
		}
		created, err := createRemoteHookParentDirectories(filepath.Dir(mutation.path))
		createdDirectories = append(createdDirectories, created...)
		if err != nil {
			return createdDirectories, err
		}
		temporary, err := os.CreateTemp(filepath.Dir(mutation.path), ".cmux-hooks-*")
		if err != nil {
			return createdDirectories, err
		}
		mutation.temporaryPath = temporary.Name()
		if _, err := temporary.Write(mutation.data); err != nil {
			_ = temporary.Close()
			return createdDirectories, err
		}
		if err := temporary.Chmod(mutation.mode); err != nil {
			_ = temporary.Close()
			return createdDirectories, err
		}
		if err := temporary.Close(); err != nil {
			return createdDirectories, err
		}
	}
	return createdDirectories, nil
}

func createRemoteHookParentDirectories(path string) ([]string, error) {
	var missing []string
	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err == nil {
			if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
				return missing, fmt.Errorf("unsupported hook config parent at %s", current)
			}
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return missing, err
		}
		missing = append(missing, current)
		parent := filepath.Dir(current)
		if parent == current {
			return missing, fmt.Errorf("no existing parent for hook config path %s", path)
		}
	}
	var created []string
	for index := len(missing) - 1; index >= 0; index-- {
		if err := os.Mkdir(missing[index], 0o700); err != nil {
			return created, err
		}
		created = append(created, missing[index])
	}
	return created, nil
}

func rollbackRemoteHookMutations(states []remoteHookFileState) error {
	var rollbackErr error
	for index := len(states) - 1; index >= 0; index-- {
		state := states[index]
		if state.existed {
			rollbackErr = errors.Join(rollbackErr, writeRemoteHookFileAtomically(state.path, state.data, state.mode))
			continue
		}
		if err := os.Remove(state.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			rollbackErr = errors.Join(rollbackErr, err)
		}
	}
	return rollbackErr
}

func writeRemoteHookFileAtomically(path string, data []byte, mode os.FileMode) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".cmux-hooks-rollback-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer func() {
		_ = temporary.Close()
		_ = os.Remove(temporaryPath)
	}()
	if _, err := temporary.Write(data); err != nil {
		return err
	}
	if err := temporary.Chmod(mode.Perm()); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func cleanupRemoteHookStaging(mutations []preparedRemoteHookMutation, createdDirectories []string) {
	cleanupRemoteHookTemporaryFiles(mutations)
	for index := len(createdDirectories) - 1; index >= 0; index-- {
		_ = os.Remove(createdDirectories[index])
	}
}

func cleanupRemoteHookTemporaryFiles(mutations []preparedRemoteHookMutation) {
	for _, mutation := range mutations {
		if mutation.temporaryPath != "" {
			_ = os.Remove(mutation.temporaryPath)
		}
	}
}

func remoteHookMutationAllowed(path string, allowedPaths, recursivePaths []string) bool {
	for _, root := range allowedPaths {
		root = filepath.Clean(root)
		if path == root {
			return true
		}
	}
	for _, root := range recursivePaths {
		root = filepath.Clean(root)
		relative, err := filepath.Rel(root, path)
		if err == nil && relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
			return true
		}
	}
	return false
}
