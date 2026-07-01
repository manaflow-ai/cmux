package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type relayAuthState struct {
	RelayID    string `json:"relay_id"`
	RelayToken string `json:"relay_token"`
}

// commandSpec describes a single CLI command and how to relay it.
type commandSpec struct {
	name     string // CLI command name (e.g. "ping", "new-window")
	v2Method string // JSON-RPC method name
	// flagKeys lists parameter keys this command accepts.
	// They are extracted from --key flags and added to params.
	flagKeys []string
	// boolFlags lists flag keys whose values should be sent as JSON booleans
	// rather than strings. Accepted values: "true", "false", "1", "0".
	boolFlags []string
	// noParams means the command takes no parameters at all.
	noParams bool
	// paramKeyOverrides remaps specific flags for compatibility aliases.
	paramKeyOverrides map[string]string
	// defaultParams are applied before flags/env fallbacks.
	defaultParams map[string]any
	// positionalKey is the param name that receives positional arguments.
	// All positional args are joined with a space and assigned to this key.
	positionalKey string
	// repeatKeys lists flags that may appear multiple times. Their values
	// accumulate in parsedFlags.repeated rather than parsedFlags.flags.
	repeatKeys []string
}

type browserCommandSpec struct {
	method                string
	flagKeys              []string
	allowPositionalURL    bool
	allowPositionalScript bool
	allowPositionalKey    bool
	allowPositionalQuery  bool
	allowPositionalValue  bool
	useWorkspaceEnv       bool
	useSurfaceEnv         bool
}

var browserCommands = map[string]browserCommandSpec{
	"open":       {method: "browser.open_split", flagKeys: []string{"url", "workspace", "surface"}, allowPositionalURL: true, useWorkspaceEnv: true},
	"open-split": {method: "browser.open_split", flagKeys: []string{"url", "workspace", "surface"}, allowPositionalURL: true, useWorkspaceEnv: true},
	"new":        {method: "browser.open_split", flagKeys: []string{"url", "workspace", "surface"}, allowPositionalURL: true, useWorkspaceEnv: true},
	"navigate":   {method: "browser.navigate", flagKeys: []string{"url", "surface"}, allowPositionalURL: true, useSurfaceEnv: true},
	"goto":       {method: "browser.navigate", flagKeys: []string{"url", "surface"}, allowPositionalURL: true, useSurfaceEnv: true},
	"back":       {method: "browser.back", flagKeys: []string{"surface"}, useSurfaceEnv: true},
	"forward":    {method: "browser.forward", flagKeys: []string{"surface"}, useSurfaceEnv: true},
	"reload":     {method: "browser.reload", flagKeys: []string{"surface"}, useSurfaceEnv: true},
	"get-url":    {method: "browser.url.get", flagKeys: []string{"surface"}, useSurfaceEnv: true},
	"url":        {method: "browser.url.get", flagKeys: []string{"surface"}, useSurfaceEnv: true},
	"snapshot":   {method: "browser.snapshot", flagKeys: []string{"surface", "selector", "max-depth"}, useSurfaceEnv: true},
	"eval":       {method: "browser.eval", flagKeys: []string{"surface", "script"}, allowPositionalScript: true, useSurfaceEnv: true},
	"wait":       {method: "browser.wait", flagKeys: []string{"surface", "selector", "text", "url-contains", "load-state", "function", "timeout-ms"}, useSurfaceEnv: true},
	"click":      {method: "browser.click", flagKeys: []string{"surface", "selector"}, allowPositionalQuery: true, useSurfaceEnv: true},
	"dblclick":   {method: "browser.dblclick", flagKeys: []string{"surface", "selector"}, allowPositionalQuery: true, useSurfaceEnv: true},
	"hover":      {method: "browser.hover", flagKeys: []string{"surface", "selector"}, allowPositionalQuery: true, useSurfaceEnv: true},
	"focus":      {method: "browser.focus", flagKeys: []string{"surface", "selector"}, allowPositionalQuery: true, useSurfaceEnv: true},
	"check":      {method: "browser.check", flagKeys: []string{"surface", "selector"}, allowPositionalQuery: true, useSurfaceEnv: true},
	"uncheck":    {method: "browser.uncheck", flagKeys: []string{"surface", "selector"}, allowPositionalQuery: true, useSurfaceEnv: true},
	"type":       {method: "browser.type", flagKeys: []string{"surface", "selector", "text"}, allowPositionalValue: true, useSurfaceEnv: true},
	"fill":       {method: "browser.fill", flagKeys: []string{"surface", "selector", "text"}, allowPositionalValue: true, useSurfaceEnv: true},
	"press":      {method: "browser.press", flagKeys: []string{"surface", "key"}, allowPositionalKey: true, useSurfaceEnv: true},
	"key":        {method: "browser.press", flagKeys: []string{"surface", "key"}, allowPositionalKey: true, useSurfaceEnv: true},
	"keydown":    {method: "browser.keydown", flagKeys: []string{"surface", "key"}, allowPositionalKey: true, useSurfaceEnv: true},
	"keyup":      {method: "browser.keyup", flagKeys: []string{"surface", "key"}, allowPositionalKey: true, useSurfaceEnv: true},
	"select":     {method: "browser.select", flagKeys: []string{"surface", "selector", "value"}, allowPositionalValue: true, useSurfaceEnv: true},
	"screenshot": {method: "browser.screenshot", flagKeys: []string{"surface"}, useSurfaceEnv: true},
}

var commandIndex map[string]*commandSpec

func init() {
	// Apply per-command overrides from cli_overrides.go onto the generated specs.
	for i := range commands {
		ov, ok := commandOverrides[commands[i].name]
		if !ok {
			continue
		}
		if ov.paramKeyOverrides != nil {
			commands[i].paramKeyOverrides = ov.paramKeyOverrides
		}
		if ov.positionalKey != "" {
			commands[i].positionalKey = ov.positionalKey
		}
		if ov.defaultParams != nil {
			commands[i].defaultParams = ov.defaultParams
		}
	}
	commandIndex = make(map[string]*commandSpec, len(commands))
	for i := range commands {
		commandIndex[commands[i].name] = &commands[i]
	}
}

// runCLI is the entry point for the "cli" subcommand (or busybox "cmux" invocation).
func runCLI(args []string) int {
	socketPath := os.Getenv("CMUX_SOCKET_PATH")

	// Parse global flags
	var jsonOutput bool
	var remaining []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "cmux: --socket requires a path")
				return 2
			}
			socketPath = args[i+1]
			i++
		case "--json":
			jsonOutput = true
		case "--help", "-h":
			cliUsage()
			return 0
		default:
			remaining = append(remaining, args[i:]...)
			goto doneFlags
		}
	}
doneFlags:

	if len(remaining) == 0 {
		cliUsage()
		return 2
	}
	cmdName := remaining[0]
	cmdArgs := remaining[1:]
	if cmdName == "help" {
		cliUsage()
		return 0
	}

	// refreshAddr is set when the address came from socket_addr file (not env/flag),
	// allowing one stale-address refresh if another workspace has replaced socket_addr.
	var refreshAddr func() string
	if socketPath == "" {
		socketPath = readSocketAddrFile()
		refreshAddr = readSocketAddrFile
	}
	if socketPath == "" {
		fmt.Fprintln(os.Stderr, "cmux: CMUX_SOCKET_PATH not set and --socket not provided")
		return 1
	}

	// Special case: "rpc" passthrough
	if cmdName == "rpc" {
		return runRPC(socketPath, cmdArgs, jsonOutput, refreshAddr)
	}

	// Commands with specialDispatch=true in cli_overrides.go have dedicated
	// handler functions for client-side logic the generic path cannot express.
	if commandOverrides[cmdName].specialDispatch {
		switch cmdName {
		case "new-workspace":
			return runNewWorkspaceRelay(socketPath, cmdArgs, jsonOutput, refreshAddr)
		}
	}

	// Browser subcommand delegation
	if cmdName == "browser" {
		return runBrowserRelay(socketPath, cmdArgs, jsonOutput, refreshAddr)
	}

	// Workspace group subcommands: "workspace-group <sub>" and the canonical
	// two-word "workspace group <sub>" both map to workspace.group.* methods,
	// matching the macOS cmux CLI.
	if cmdName == "workspace-group" {
		return runWorkspaceGroupRelay(socketPath, cmdArgs, jsonOutput, refreshAddr)
	}
	if cmdName == "workspace" {
		if len(cmdArgs) > 0 && cmdArgs[0] == "group" {
			return runWorkspaceGroupRelay(socketPath, cmdArgs[1:], jsonOutput, refreshAddr)
		}
		fmt.Fprintln(os.Stderr, "cmux workspace: only the \"group\" subcommand is supported here. Use list-workspaces, new-workspace, close-workspace, or select-workspace for workspace operations.")
		return 2
	}

	// Agent launch commands
	if cmdName == "claude-teams" {
		return runClaudeTeamsRelay(socketPath, cmdArgs, refreshAddr)
	}
	if cmdName == "omo" {
		return runOMORelay(socketPath, cmdArgs, refreshAddr)
	}
	if cmdName == "omx" {
		return runOMXRelay(socketPath, cmdArgs, refreshAddr)
	}
	if cmdName == "omc" {
		return runOMCRelay(socketPath, cmdArgs, refreshAddr)
	}

	// Tmux compatibility layer (used by agent shims)
	if cmdName == "__tmux-compat" {
		return runTmuxCompat(socketPath, cmdArgs, refreshAddr)
	}

	spec, ok := commandIndex[cmdName]
	if !ok {
		fmt.Fprintf(os.Stderr, "cmux: unknown command %q\n", cmdName)
		return 2
	}

	return execV2(socketPath, spec, cmdArgs, jsonOutput, refreshAddr)
}

// execV2 sends a v2 JSON-RPC request over the socket.
func execV2(socketPath string, spec *commandSpec, args []string, jsonOutput bool, refreshAddr func() string) int {
	params := make(map[string]any, len(spec.defaultParams))
	for key, value := range spec.defaultParams {
		params[key] = value
	}

	if !spec.noParams {
		parsed, err := parseFlags(args, spec.flagKeys, spec.repeatKeys)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
			return 2
		}
		// Build a set of bool flags for O(1) lookup.
		boolFlagSet := make(map[string]struct{}, len(spec.boolFlags))
		for _, k := range spec.boolFlags {
			boolFlagSet[k] = struct{}{}
		}

		// Map flag keys to JSON param keys (e.g. "workspace" → "workspace_id" where appropriate).
		// Flags listed in boolFlags are coerced to JSON booleans instead of sent as strings.
		for _, key := range spec.flagKeys {
			if val, ok := parsed.flags[key]; ok {
				paramKey := flagToParamKey(key)
				if override, ok := spec.paramKeyOverrides[key]; ok {
					paramKey = override
				}
				if _, isBool := boolFlagSet[key]; isBool {
					switch strings.ToLower(val) {
					case "true", "1", "yes":
						params[paramKey] = true
					case "false", "0", "no":
						params[paramKey] = false
					default:
						fmt.Fprintf(os.Stderr, "cmux: --%s must be true or false\n", key)
						return 2
					}
				} else {
					params[paramKey] = val
				}
			}
		}

		if len(parsed.positional) > 0 {
			if spec.positionalKey != "" {
				params[spec.positionalKey] = strings.Join(parsed.positional, " ")
			} else {
				fmt.Fprintf(os.Stderr, "cmux: %s does not accept positional arguments\n", spec.name)
				return 2
			}
		}

		if specUsesParam(spec, "workspace_id") {
			applyWorkspaceEnvFallback(params)
		}
		if specUsesParam(spec, "surface_id") {
			applySurfaceEnvFallback(params)
		}
	}

	resp, err := socketRoundTripV2(socketPath, spec.v2Method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}

	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

// runNewWorkspaceRelay handles "cmux new-workspace" with full flag parity to the
// macOS CLI: --layout (JSON object), --env (repeatable KEY=VALUE), --env-file
// (file of KEY=VALUE lines), and --command (post-create send+return).
func runNewWorkspaceRelay(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	flagKeys := []string{"name", "cwd", "description", "focus", "window", "group", "group-placement", "group-reference", "layout", "env-file", "command"}
	repeatKeys := []string{"env"}

	parsed, err := parseFlags(args, flagKeys, repeatKeys)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux new-workspace: %v\n", err)
		return 2
	}
	if len(parsed.positional) > 0 {
		fmt.Fprintln(os.Stderr, "cmux: new-workspace does not accept positional arguments")
		return 2
	}

	params := make(map[string]any)

	for _, key := range []string{"name", "cwd", "description", "window", "group", "group-placement", "group-reference", "command"} {
		if val, ok := parsed.flags[key]; ok {
			paramKey := flagToParamKey(key)
			switch key {
			case "name":
				paramKey = "title"
			case "group-placement":
				paramKey = "placement"
			case "group-reference":
				paramKey = "group_reference_workspace_id"
			case "command":
				// handled post-create; do not send to workspace.create
				continue
			}
			params[paramKey] = val
		}
	}

	if val, ok := parsed.flags["focus"]; ok {
		switch strings.ToLower(val) {
		case "true", "1", "yes":
			params["focus"] = true
		case "false", "0", "no":
			params["focus"] = false
		default:
			fmt.Fprintf(os.Stderr, "cmux: --focus must be true or false\n")
			return 2
		}
	}

	if val, ok := parsed.flags["layout"]; ok {
		var layout any
		if err := json.Unmarshal([]byte(val), &layout); err != nil {
			fmt.Fprintf(os.Stderr, "cmux new-workspace: --layout must be valid JSON: %v\n", err)
			return 2
		}
		params["layout"] = layout
	}

	// Build env dict from --env KEY=VALUE pairs and --env-file lines.
	env := make(map[string]string)
	for _, kv := range parsed.repeated["env"] {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			fmt.Fprintf(os.Stderr, "cmux new-workspace: --env %q must be KEY=VALUE\n", kv)
			return 2
		}
		env[k] = v
	}
	if envFile, ok := parsed.flags["env-file"]; ok {
		data, err := os.ReadFile(envFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux new-workspace: --env-file: %v\n", err)
			return 2
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				fmt.Fprintf(os.Stderr, "cmux new-workspace: --env-file line %q must be KEY=VALUE\n", line)
				return 2
			}
			env[k] = v
		}
	}
	if len(env) > 0 {
		params["env"] = env
	}

	resp, err := socketRoundTripV2(socketPath, "workspace.create", params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}

	// --command: send text + Enter to the new workspace's surface.
	if cmd, ok := parsed.flags["command"]; ok {
		var result map[string]any
		if err := json.Unmarshal([]byte(resp), &result); err == nil {
			if surfaceID, _ := result["surface_id"].(string); surfaceID != "" {
				sendParams := map[string]any{"surface_id": surfaceID, "text": cmd}
				if _, err := socketRoundTripV2(socketPath, "surface.send_text", sendParams, refreshAddr); err != nil {
					fmt.Fprintf(os.Stderr, "cmux new-workspace: --command send failed: %v\n", err)
					return 1
				}
				keyParams := map[string]any{"surface_id": surfaceID, "key": "return"}
				if _, err := socketRoundTripV2(socketPath, "surface.send_key", keyParams, refreshAddr); err != nil {
					fmt.Fprintf(os.Stderr, "cmux new-workspace: --command send-key failed: %v\n", err)
					return 1
				}
			}
		}
	}

	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

// runRPC sends an arbitrary JSON-RPC method with optional JSON params.
func runRPC(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "cmux rpc: requires a method name")
		return 2
	}
	method := args[0]
	var params map[string]any
	if len(args) > 1 {
		if err := json.Unmarshal([]byte(args[1]), &params); err != nil {
			fmt.Fprintf(os.Stderr, "cmux rpc: invalid JSON params: %v\n", err)
			return 2
		}
	}

	resp, err := socketRoundTripV2(socketPath, method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	fmt.Println(resp)
	return 0
}

// workspaceGroupFlagKeys lists the flags each "workspace group" subcommand
// accepts. Every subcommand also takes --window to target a non-focused window.
var workspaceGroupFlagKeys = map[string][]string{
	"list":          {"window"},
	"create":        {"name", "cwd", "from", "window"},
	"ungroup":       {"group", "window"},
	"delete":        {"group", "window"},
	"rename":        {"group", "name", "window"},
	"collapse":      {"group", "window"},
	"expand":        {"group", "window"},
	"pin":           {"group", "window"},
	"unpin":         {"group", "window"},
	"add":           {"group", "workspace", "window"},
	"remove":        {"workspace", "window"},
	"set-anchor":    {"group", "workspace", "window"},
	"new-workspace": {"group", "placement", "window"},
	"set-color":     {"group", "hex", "window"},
	"set-icon":      {"group", "symbol", "window"},
	"move":          {"group", "to-index", "before", "after", "window"},
	"focus":         {"group", "window"},
}

// runWorkspaceGroupRelay handles "cmux workspace group <sub>" (and the
// "workspace-group" alias) by mapping each subcommand to its
// workspace.group.* v2 method, mirroring the macOS cmux CLI flags.
func runWorkspaceGroupRelay(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	const subcommandHint = "list, create, ungroup, delete, rename, collapse, expand, pin, unpin, add, remove, set-anchor, new-workspace, set-color, set-icon, move, focus"
	if len(args) == 0 {
		fmt.Fprintf(os.Stderr, "cmux workspace group: requires a subcommand (%s)\n", subcommandHint)
		return 2
	}
	sub := args[0]
	flagKeys, ok := workspaceGroupFlagKeys[sub]
	if !ok {
		fmt.Fprintf(os.Stderr, "cmux workspace group: unknown subcommand %q (%s)\n", sub, subcommandHint)
		return 2
	}

	fail := func(format string, a ...any) int {
		fmt.Fprintf(os.Stderr, "cmux workspace group %s: %s\n", sub, fmt.Sprintf(format, a...))
		return 2
	}

	parsed, err := parseFlags(args[1:], flagKeys)
	if err != nil {
		return fail("%v", err)
	}

	params := make(map[string]any)
	if win, ok := parsed.flags["window"]; ok {
		params["window_id"] = win
	}

	// The group id comes from --group or the first positional argument.
	// takeGroupID consumes that positional so later positionals (e.g. the
	// rename name) are still available.
	positional := parsed.positional
	takeGroupID := func() bool {
		if gid, ok := parsed.flags["group"]; ok {
			params["group_id"] = gid
			return true
		}
		if len(positional) > 0 {
			params["group_id"] = positional[0]
			positional = positional[1:]
			return true
		}
		return false
	}

	switch sub {
	case "list":
		// No parameters beyond the optional window.

	case "create":
		name, ok := parsed.flags["name"]
		if !ok && len(positional) > 0 {
			name = positional[0]
		}
		params["name"] = name
		if cwd, ok := parsed.flags["cwd"]; ok {
			params["cwd"] = cwd
		}
		if from, ok := parsed.flags["from"]; ok {
			ids := []string{}
			for _, id := range strings.Split(from, ",") {
				if id = strings.TrimSpace(id); id != "" {
					ids = append(ids, id)
				}
			}
			params["child_workspace_ids"] = ids
		}

	case "ungroup", "delete", "collapse", "expand", "pin", "unpin", "focus":
		if !takeGroupID() {
			return fail("requires a group id or --group <id>")
		}

	case "rename":
		if !takeGroupID() {
			return fail("requires a group id or --group <id>")
		}
		name, ok := parsed.flags["name"]
		if !ok && len(positional) > 0 {
			name, ok = positional[0], true
		}
		if !ok {
			return fail("requires --name <name>")
		}
		params["name"] = name

	case "add", "set-anchor":
		gid, hasGroup := parsed.flags["group"]
		ws, hasWorkspace := parsed.flags["workspace"]
		if !hasGroup || !hasWorkspace {
			return fail("requires --group <id> --workspace <id>")
		}
		params["group_id"] = gid
		params["workspace_id"] = ws

	case "remove":
		ws, ok := parsed.flags["workspace"]
		if !ok && len(positional) > 0 {
			ws, ok = positional[0], true
		}
		if !ok {
			return fail("requires --workspace <id>")
		}
		params["workspace_id"] = ws

	case "new-workspace":
		if !takeGroupID() {
			return fail("requires a group id or --group <id>")
		}
		if placement, ok := parsed.flags["placement"]; ok {
			params["placement"] = placement
		}

	case "set-color":
		if !takeGroupID() {
			return fail("requires a group id or --group <id>")
		}
		// Omitting --hex clears the color, matching the macOS CLI.
		params["hex"] = parsed.flags["hex"]

	case "set-icon":
		if !takeGroupID() {
			return fail("requires a group id or --group <id>")
		}
		// Omitting --symbol clears the icon, matching the macOS CLI.
		params["symbol"] = parsed.flags["symbol"]

	case "move":
		if !takeGroupID() {
			return fail("requires a group id or --group <id>")
		}
		if v, ok := parsed.flags["to-index"]; ok {
			n, err := strconv.Atoi(v)
			if err != nil {
				return fail("--to-index must be an integer")
			}
			params["to_index"] = n
		} else if v, ok := parsed.flags["before"]; ok {
			params["before_group_id"] = v
		} else if v, ok := parsed.flags["after"]; ok {
			params["after_group_id"] = v
		} else {
			return fail("requires --to-index <n>, --before <group>, or --after <group>")
		}
	}

	// Forward the SSH caller's workspace/surface context so methods without a
	// group id (list, create) resolve the caller's window instead of whichever
	// local window is focused. Group-id routing still wins server-side, and
	// subcommands that require an explicit --workspace have already validated
	// it above, so the fallback never satisfies a missing required flag.
	applyWorkspaceEnvFallback(params)
	applySurfaceEnvFallback(params)

	method := "workspace.group." + strings.ReplaceAll(sub, "-", "_")
	resp, err := socketRoundTripV2(socketPath, method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

// runBrowserRelay handles "cmux browser <subcommand>" by mapping to browser.* v2 methods.
func runBrowserRelay(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	if len(args) == 0 {
		fmt.Fprintf(os.Stderr, "cmux browser: requires a subcommand (%s)\n", browserSubcommandHint())
		return 2
	}

	sub := args[0]
	subArgs := args[1:]

	spec, ok := browserCommands[sub]
	if !ok {
		fmt.Fprintf(os.Stderr, "cmux browser: unknown subcommand %q\n", sub)
		return 2
	}

	params := make(map[string]any)
	parsed, err := parseFlags(subArgs, spec.flagKeys)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux browser: %v\n", err)
		return 2
	}
	for _, key := range spec.flagKeys {
		if val, ok := parsed.flags[key]; ok {
			paramKey := flagToParamKey(key)
			params[paramKey] = val
		}
	}
	if spec.allowPositionalURL {
		if _, ok := params["url"]; !ok && len(parsed.positional) > 0 {
			params["url"] = strings.Join(parsed.positional, " ")
		}
	}
	if spec.allowPositionalScript {
		if _, ok := params["script"]; !ok && len(parsed.positional) > 0 {
			params["script"] = strings.Join(parsed.positional, " ")
		}
	}
	if spec.allowPositionalKey {
		if _, ok := params["key"]; !ok && len(parsed.positional) > 0 {
			params["key"] = strings.Join(parsed.positional, " ")
		}
	}
	if spec.allowPositionalQuery {
		if _, ok := params["selector"]; !ok && len(parsed.positional) > 0 {
			params["selector"] = strings.Join(parsed.positional, " ")
		}
	}
	if spec.allowPositionalValue {
		applyBrowserValuePositionals(
			params,
			parsed.positional,
			browserSpecSupportsParam(spec, "value"),
			browserSpecSupportsParam(spec, "text"),
		)
	}
	if spec.useWorkspaceEnv {
		applyWorkspaceEnvFallback(params)
	}
	if spec.useSurfaceEnv {
		applySurfaceEnvFallback(params)
	}

	resp, err := socketRoundTripV2(socketPath, spec.method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

func browserSubcommandHint() string {
	names := make([]string, 0, len(browserCommands))
	for name := range browserCommands {
		names = append(names, name)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

func browserSpecSupportsParam(spec browserCommandSpec, paramKey string) bool {
	for _, key := range spec.flagKeys {
		if flagToParamKey(key) == paramKey {
			return true
		}
	}
	return false
}

func applyBrowserValuePositionals(params map[string]any, positionals []string, allowValue bool, allowText bool) {
	if len(positionals) == 0 {
		return
	}
	if _, ok := params["selector"]; !ok {
		params["selector"] = positionals[0]
		positionals = positionals[1:]
	}
	joined := strings.Join(positionals, " ")
	if allowValue {
		if _, ok := params["value"]; !ok {
			if joined != "" {
				params["value"] = joined
			} else if text, ok := params["text"]; ok {
				params["value"] = text
			}
		}
	}
	if allowText {
		if _, ok := params["text"]; !ok {
			if joined != "" {
				params["text"] = joined
			} else if value, ok := params["value"]; ok {
				params["text"] = value
			}
		}
	}
}

// specUsesParam reports whether any of spec's flagKeys resolves to paramKey
// after applying flagToParamKey and any paramKeyOverrides.
func specUsesParam(spec *commandSpec, paramKey string) bool {
	for _, k := range spec.flagKeys {
		resolved := flagToParamKey(k)
		if override, ok := spec.paramKeyOverrides[k]; ok {
			resolved = override
		}
		if resolved == paramKey {
			return true
		}
	}
	return false
}

func applyWorkspaceEnvFallback(params map[string]any) {
	if _, ok := params["workspace_id"]; ok {
		return
	}
	if envWs := os.Getenv("CMUX_WORKSPACE_ID"); envWs != "" {
		params["workspace_id"] = envWs
	}
}

func applySurfaceEnvFallback(params map[string]any) {
	if _, ok := params["surface_id"]; ok {
		return
	}
	if envSf := os.Getenv("CMUX_SURFACE_ID"); envSf != "" {
		params["surface_id"] = envSf
	}
}

func defaultRelayOutput(resp string) string {
	var result any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		trimmed := strings.TrimSpace(resp)
		if trimmed == "" {
			return "OK"
		}
		return trimmed
	}

	if relayResultIsEmpty(result) {
		return "OK"
	}

	switch typed := result.(type) {
	case string:
		return typed
	default:
		encoded, err := json.MarshalIndent(typed, "", "  ")
		if err != nil {
			return "OK"
		}
		return string(encoded)
	}
}

func relayResultIsEmpty(result any) bool {
	switch typed := result.(type) {
	case nil:
		return true
	case map[string]any:
		return len(typed) == 0
	case []any:
		return len(typed) == 0
	case string:
		return typed == ""
	default:
		return false
	}
}

// flagToParamKey maps a CLI flag name to its JSON-RPC param key.
func flagToParamKey(key string) string {
	switch key {
	case "workspace":
		return "workspace_id"
	case "surface":
		return "surface_id"
	case "panel":
		return "panel_id"
	case "pane":
		return "pane_id"
	case "window":
		return "window_id"
	case "group":
		return "group_id"
	case "command":
		return "initial_command"
	case "name":
		return "title"
	case "working-directory":
		return "working_directory"
	case "max-depth":
		return "max_depth"
	case "timeout-ms":
		return "timeout_ms"
	case "url-contains":
		return "url_contains"
	case "load-state":
		return "load_state"
	default:
		return key
	}
}

// parsedFlags holds the results of flag parsing.
type parsedFlags struct {
	flags      map[string]string   // --key value pairs (last wins for duplicates)
	repeated   map[string][]string // --key values for repeat-allowed keys
	positional []string            // non-flag arguments
}

// parseFlags extracts --key value pairs from args for the given allowed keys.
// Keys listed in repeatKeys may appear more than once; their values accumulate
// in repeated rather than flags. Non-flag arguments are collected in positional.
func parseFlags(args []string, keys []string, repeatKeys ...[]string) (parsedFlags, error) {
	allowed := make(map[string]bool, len(keys))
	for _, k := range keys {
		allowed[k] = true
	}
	repeat := make(map[string]bool)
	if len(repeatKeys) > 0 {
		for _, k := range repeatKeys[0] {
			repeat[k] = true
			allowed[k] = true
		}
	}

	result := parsedFlags{
		flags:    make(map[string]string),
		repeated: make(map[string][]string),
	}
	for i := 0; i < len(args); i++ {
		if args[i] == "--" {
			result.positional = append(result.positional, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(args[i], "--") {
			result.positional = append(result.positional, args[i])
			continue
		}
		key := strings.TrimPrefix(args[i], "--")
		if !allowed[key] {
			return parsedFlags{}, fmt.Errorf("unknown flag --%s", key)
		}
		if i+1 >= len(args) {
			return parsedFlags{}, fmt.Errorf("flag --%s requires a value", key)
		}
		val := args[i+1]
		i++
		if repeat[key] {
			result.repeated[key] = append(result.repeated[key], val)
		} else {
			result.flags[key] = val
		}
	}
	return result, nil
}

// readSocketAddrFile reads the socket address from ~/.cmux/socket_addr as a fallback
// when CMUX_SOCKET_PATH is not set. Written by the cmux app after the relay establishes.
func readSocketAddrFile() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(home, ".cmux", "socket_addr"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func readRelayAuthFile(socketPath string) *relayAuthState {
	if strings.Contains(socketPath, ":") && !strings.HasPrefix(socketPath, "/") {
		_, port, err := net.SplitHostPort(socketPath)
		if err != nil || port == "" {
			return nil
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return nil
		}
		data, err := os.ReadFile(filepath.Join(home, ".cmux", "relay", port+".auth"))
		if err != nil {
			return nil
		}
		var state relayAuthState
		if err := json.Unmarshal(data, &state); err != nil {
			return nil
		}
		if state.RelayID == "" || state.RelayToken == "" {
			return nil
		}
		return &state
	}
	return nil
}

func currentRelayAuth(socketPath string) *relayAuthState {
	relayID := strings.TrimSpace(os.Getenv("CMUX_RELAY_ID"))
	relayToken := strings.TrimSpace(os.Getenv("CMUX_RELAY_TOKEN"))
	if relayID != "" && relayToken != "" {
		return &relayAuthState{RelayID: relayID, RelayToken: relayToken}
	}
	return readRelayAuthFile(socketPath)
}

// dialSocket connects to the cmux socket. If addr contains a colon and doesn't
// start with '/', it's treated as a TCP address (host:port); otherwise Unix socket.
// For TCP connections, refreshAddr is used only to recover from a stale socket_addr
// rewrite, not to poll for relay readiness.
func dialSocket(addr string, refreshAddr func() string) (net.Conn, error) {
	if strings.Contains(addr, ":") && !strings.HasPrefix(addr, "/") {
		conn, connectedAddr, err := dialTCP(addr)
		if err != nil && refreshAddr != nil && isConnectionRefused(err) {
			if refreshedAddr := strings.TrimSpace(refreshAddr()); refreshedAddr != "" && refreshedAddr != addr {
				addr = refreshedAddr
				conn, connectedAddr, err = dialTCP(addr)
			}
		}
		if err != nil {
			return nil, err
		}
		if auth := currentRelayAuth(connectedAddr); auth != nil {
			if err := authenticateRelayConn(conn, auth); err != nil {
				conn.Close()
				return nil, err
			}
		}
		return conn, nil
	}
	return net.Dial("unix", addr)
}

func dialTCP(addr string) (net.Conn, string, error) {
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		return nil, addr, err
	}
	setTCPNoDelay(conn)
	return conn, addr, nil
}

func isConnectionRefused(err error) bool {
	if opErr, ok := err.(*net.OpError); ok {
		return strings.Contains(opErr.Err.Error(), "connection refused")
	}
	return strings.Contains(err.Error(), "connection refused")
}

func authenticateRelayConn(conn net.Conn, auth *relayAuthState) error {
	reader := bufio.NewReader(conn)
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	var challenge struct {
		Protocol string `json:"protocol"`
		Version  int    `json:"version"`
		RelayID  string `json:"relay_id"`
		Nonce    string `json:"nonce"`
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("failed to read relay auth challenge: %w", err)
	}
	if err := json.Unmarshal([]byte(line), &challenge); err != nil {
		return fmt.Errorf("invalid relay auth challenge")
	}
	if challenge.Protocol != "cmux-relay-auth" || challenge.Version != 1 || challenge.RelayID != auth.RelayID || challenge.Nonce == "" {
		return fmt.Errorf("relay auth challenge mismatch")
	}

	tokenBytes, err := hex.DecodeString(auth.RelayToken)
	if err != nil {
		return fmt.Errorf("invalid relay auth token")
	}
	mac := computeRelayMAC(tokenBytes, auth.RelayID, challenge.Nonce, challenge.Version)
	payload, err := json.Marshal(map[string]any{
		"relay_id": auth.RelayID,
		"mac":      hex.EncodeToString(mac),
	})
	if err != nil {
		return fmt.Errorf("failed to encode relay auth response: %w", err)
	}
	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return fmt.Errorf("failed to send relay auth response: %w", err)
	}

	line, err = reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("failed to read relay auth result: %w", err)
	}
	var result struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal([]byte(line), &result); err != nil {
		return fmt.Errorf("invalid relay auth result")
	}
	if !result.OK {
		return fmt.Errorf("relay auth rejected")
	}
	_ = conn.SetDeadline(time.Time{})
	return nil
}

func computeRelayMAC(token []byte, relayID, nonce string, version int) []byte {
	mac := hmac.New(sha256.New, token)
	_, _ = io.WriteString(mac, fmt.Sprintf("relay_id=%s\nnonce=%s\nversion=%d", relayID, nonce, version))
	return mac.Sum(nil)
}

// socketRoundTripV2 sends a JSON-RPC request and returns the result JSON.
func socketRoundTripV2(socketPath, method string, params map[string]any, refreshAddr func() string) (string, error) {
	conn, err := dialSocket(socketPath, refreshAddr)
	if err != nil {
		return "", fmt.Errorf("failed to connect to %s: %w", socketPath, err)
	}
	defer conn.Close()

	id := randomHex(8)
	req := map[string]any{
		"id":     id,
		"method": method,
	}
	if params != nil {
		req["params"] = params
	} else {
		req["params"] = map[string]any{}
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("failed to marshal request: %w", err)
	}

	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return "", fmt.Errorf("failed to send request: %w", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", fmt.Errorf("failed to read response: %w", err)
	}

	// Parse the response to check for errors
	var resp map[string]any
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		return strings.TrimRight(line, "\n"), nil
	}

	if ok, _ := resp["ok"].(bool); !ok {
		if errObj, _ := resp["error"].(map[string]any); errObj != nil {
			code, _ := errObj["code"].(string)
			msg, _ := errObj["message"].(string)
			return "", fmt.Errorf("server error [%s]: %s", code, msg)
		}
		return "", fmt.Errorf("server returned error response")
	}

	// Return the result portion as JSON
	if result, ok := resp["result"]; ok {
		resultJSON, err := json.Marshal(result)
		if err != nil {
			return "", fmt.Errorf("failed to marshal result: %w", err)
		}
		return string(resultJSON), nil
	}

	return "{}", nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func cliUsage() {
	fmt.Fprintln(os.Stderr, "Usage: cmux [--socket <path>] [--json] <command> [args...]")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Commands:")
	fmt.Fprintln(os.Stderr, "  ping                      Check connectivity")
	fmt.Fprintln(os.Stderr, "  capabilities              List server capabilities")
	fmt.Fprintln(os.Stderr, "  list-workspaces           List all workspaces")
	fmt.Fprintln(os.Stderr, "  new-workspace             Create a new workspace")
	fmt.Fprintln(os.Stderr, "    --name <title>          Workspace title")
	fmt.Fprintln(os.Stderr, "    --cwd <dir>             Working directory")
	fmt.Fprintln(os.Stderr, "    --description <text>    Workspace description")
	fmt.Fprintln(os.Stderr, "    --focus true|false      Focus the workspace after creation")
	fmt.Fprintln(os.Stderr, "    --window <id>           Target window")
	fmt.Fprintln(os.Stderr, "    --group <id>            Workspace group to place into")
	fmt.Fprintln(os.Stderr, "    --group-placement <p>   Placement within the group (before|after|...)")
	fmt.Fprintln(os.Stderr, "    --group-reference <id>  Reference workspace for placement")
	fmt.Fprintln(os.Stderr, "    --layout <json>         Pane layout JSON object")
	fmt.Fprintln(os.Stderr, "    --env KEY=VALUE         Environment variable (repeatable)")
	fmt.Fprintln(os.Stderr, "    --env-file <path>       File of KEY=VALUE environment variables")
	fmt.Fprintln(os.Stderr, "    --command <cmd>         Command to send to the new workspace after creation")
	fmt.Fprintln(os.Stderr, "  rename-workspace          Rename a workspace")
	fmt.Fprintln(os.Stderr, "  close-workspace           Close a workspace")
	fmt.Fprintln(os.Stderr, "  select-workspace          Select a workspace")
	fmt.Fprintln(os.Stderr, "  next-workspace            Switch to next workspace")
	fmt.Fprintln(os.Stderr, "  previous-workspace        Switch to previous workspace")
	fmt.Fprintln(os.Stderr, "  last-workspace            Switch to last-used workspace")
	fmt.Fprintln(os.Stderr, "  current-workspace         Show the active workspace ID")
	fmt.Fprintln(os.Stderr, "  move-workspace-to-window  Move workspace to another window")
	fmt.Fprintln(os.Stderr, "  equalize-splits           Equalize pane splits in a workspace")
	fmt.Fprintln(os.Stderr, "  list-panes                List panes in a workspace")
	fmt.Fprintln(os.Stderr, "  new-pane                  Create a new pane")
	fmt.Fprintln(os.Stderr, "  last-pane                 Switch to last-used pane")
	fmt.Fprintln(os.Stderr, "  join-pane                 Join a pane into another")
	fmt.Fprintln(os.Stderr, "  swap-pane                 Swap two panes")
	fmt.Fprintln(os.Stderr, "  break-pane                Break a pane into its own workspace")
	fmt.Fprintln(os.Stderr, "  resize-pane               Resize a pane")
	fmt.Fprintln(os.Stderr, "  list-panels               List surfaces in a workspace")
	fmt.Fprintln(os.Stderr, "  list-pane-surfaces        List surfaces in a pane")
	fmt.Fprintln(os.Stderr, "  new-surface               Create a new surface")
	fmt.Fprintln(os.Stderr, "  new-split                 Split an existing surface")
	fmt.Fprintln(os.Stderr, "  close-surface             Close a surface")
	fmt.Fprintln(os.Stderr, "  focus-panel               Focus a surface")
	fmt.Fprintln(os.Stderr, "  refresh-surfaces          Refresh all surfaces")
	fmt.Fprintln(os.Stderr, "  send                      Send text to a surface")
	fmt.Fprintln(os.Stderr, "  send-key                  Send a key to a surface")
	fmt.Fprintln(os.Stderr, "  read-screen               Read terminal output from a surface")
	fmt.Fprintln(os.Stderr, "  clear-history             Clear scrollback history for a surface")
	fmt.Fprintln(os.Stderr, "  list-windows              List all windows")
	fmt.Fprintln(os.Stderr, "  new-window                Create a new window")
	fmt.Fprintln(os.Stderr, "  close-window              Close a window")
	fmt.Fprintln(os.Stderr, "  current-window            Show the active window ID")
	fmt.Fprintln(os.Stderr, "  focus-window              Focus a window")
	fmt.Fprintln(os.Stderr, "  notify                    Create a notification")
	fmt.Fprintln(os.Stderr, "  jump-to-unread            Jump to first unread notification")
	fmt.Fprintln(os.Stderr, "  dismiss-notification      Dismiss a notification")
	fmt.Fprintln(os.Stderr, "  mark-notification-read    Mark a notification as read")
	fmt.Fprintln(os.Stderr, "  open-notification         Open a notification")
	fmt.Fprintln(os.Stderr, "  workspace group <sub>     Manage sidebar workspace groups (list, create, ungroup,")
	fmt.Fprintln(os.Stderr, "                            delete, rename, collapse, expand, pin, unpin, add, remove,")
	fmt.Fprintln(os.Stderr, "                            set-anchor, new-workspace, set-color, set-icon, move, focus)")
	fmt.Fprintln(os.Stderr, "  browser <sub>             Browser commands through the local cmux browser relay")
	fmt.Fprintln(os.Stderr, "  claude-teams [args...]    Launch Claude Code in teammate mode")
	fmt.Fprintln(os.Stderr, "  omo [args...]             Launch OpenCode with cmux integration")
	fmt.Fprintln(os.Stderr, "  omx [args...]             Launch Oh My Codex with cmux integration")
	fmt.Fprintln(os.Stderr, "  omc [args...]             Launch Oh My Claude Code with cmux integration")
	fmt.Fprintln(os.Stderr, "  rpc <method> [json-params] Send arbitrary JSON-RPC")
}
