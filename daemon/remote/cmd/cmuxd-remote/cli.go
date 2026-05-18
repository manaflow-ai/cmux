package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
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

// protocolVersion indicates whether a command uses the v1 text or v2 JSON-RPC protocol.
type protocolVersion int

const (
	protoV1 protocolVersion = iota
	protoV2
)

// commandSpec describes a single CLI command and how to relay it.
type commandSpec struct {
	name     string          // CLI command name (e.g. "ping", "new-window")
	proto    protocolVersion // v1 text or v2 JSON-RPC
	v1Cmd    string          // v1: literal command string sent over the socket
	v2Method string          // v2: JSON-RPC method name
	// flagKeys lists parameter keys this command accepts.
	// They are extracted from --key flags and added to params.
	flagKeys []string
	// noParams means the command takes no parameters at all.
	noParams bool
	// paramKeyOverrides remaps specific flags for compatibility aliases.
	paramKeyOverrides map[string]string
	// defaultParams are applied before flags/env fallbacks.
	defaultParams map[string]any
}

type browserCommandSpec struct {
	method          string
	defaultParams   map[string]any
	positionalKeys  []string
	joinLast        bool
	useWorkspaceEnv bool
	useSurfaceEnv   bool
	flagOverrides   map[string]string
	special         browserCommandSpecial
}

type browserCommandSpecial int

const (
	browserSpecialFindNth browserCommandSpecial = iota + 1
	browserSpecialTabTarget
	browserSpecialInputArgs
	browserSpecialWait
	browserSpecialScreenshot
)

var commands = []commandSpec{
	// V1 text protocol commands
	{name: "ping", proto: protoV1, v1Cmd: "ping", noParams: true},
	{name: "new-window", proto: protoV1, v1Cmd: "new_window", noParams: true},
	{name: "current-window", proto: protoV1, v1Cmd: "current_window", noParams: true},
	{name: "close-window", proto: protoV1, v1Cmd: "close_window", flagKeys: []string{"window"}},
	{name: "focus-window", proto: protoV1, v1Cmd: "focus_window", flagKeys: []string{"window"}},
	{name: "list-windows", proto: protoV1, v1Cmd: "list_windows", noParams: true},

	// V2 JSON-RPC commands
	{name: "capabilities", proto: protoV2, v2Method: "system.capabilities", noParams: true},
	{name: "list-workspaces", proto: protoV2, v2Method: "workspace.list", noParams: true},
	{name: "new-workspace", proto: protoV2, v2Method: "workspace.create", flagKeys: []string{"command", "working-directory", "name"}},
	{name: "close-workspace", proto: protoV2, v2Method: "workspace.close", flagKeys: []string{"workspace"}},
	{name: "select-workspace", proto: protoV2, v2Method: "workspace.select", flagKeys: []string{"workspace"}},
	{name: "current-workspace", proto: protoV2, v2Method: "workspace.current", noParams: true},
	{name: "list-panels", proto: protoV2, v2Method: "surface.list", flagKeys: []string{"workspace"}},
	{name: "focus-panel", proto: protoV2, v2Method: "surface.focus", flagKeys: []string{"panel", "workspace"}, paramKeyOverrides: map[string]string{"panel": "surface_id"}},
	{name: "list-panes", proto: protoV2, v2Method: "pane.list", flagKeys: []string{"workspace"}},
	{name: "list-pane-surfaces", proto: protoV2, v2Method: "pane.surfaces", flagKeys: []string{"pane"}},
	{name: "new-pane", proto: protoV2, v2Method: "pane.create", flagKeys: []string{"workspace", "direction", "type", "url"}, defaultParams: map[string]any{"direction": "right"}},
	{name: "new-surface", proto: protoV2, v2Method: "surface.create", flagKeys: []string{"workspace", "pane", "type", "url"}},
	{name: "new-split", proto: protoV2, v2Method: "surface.split", flagKeys: []string{"surface", "direction"}},
	{name: "close-surface", proto: protoV2, v2Method: "surface.close", flagKeys: []string{"surface"}},
	{name: "send", proto: protoV2, v2Method: "surface.send_text", flagKeys: []string{"surface", "text"}},
	{name: "send-key", proto: protoV2, v2Method: "surface.send_key", flagKeys: []string{"surface", "key"}},
	{name: "notify", proto: protoV2, v2Method: "notification.create", flagKeys: []string{"title", "body", "workspace"}},
	{name: "refresh-surfaces", proto: protoV2, v2Method: "surface.refresh", noParams: true},
}

var browserCommands = map[string]browserCommandSpec{
	"open":       {method: "browser.open_split", positionalKeys: []string{"url"}, joinLast: true, useWorkspaceEnv: true},
	"open-split": {method: "browser.open_split", positionalKeys: []string{"url"}, joinLast: true, useWorkspaceEnv: true},
	"new":        {method: "browser.open_split", positionalKeys: []string{"url"}, joinLast: true, useWorkspaceEnv: true},
	"navigate":   {method: "browser.navigate", positionalKeys: []string{"url"}, joinLast: true, useSurfaceEnv: true},
	"goto":       {method: "browser.navigate", positionalKeys: []string{"url"}, joinLast: true, useSurfaceEnv: true},
	"back":       {method: "browser.back", useSurfaceEnv: true},
	"forward":    {method: "browser.forward", useSurfaceEnv: true},
	"reload":     {method: "browser.reload", useSurfaceEnv: true},
	"get-url":    {method: "browser.url.get", useSurfaceEnv: true},
	"url":        {method: "browser.url.get", useSurfaceEnv: true},

	"focus-webview":      {method: "browser.focus_webview", useSurfaceEnv: true},
	"is-webview-focused": {method: "browser.is_webview_focused", useSurfaceEnv: true},
	"snapshot":           {method: "browser.snapshot", useSurfaceEnv: true},
	"eval":               {method: "browser.eval", positionalKeys: []string{"script"}, joinLast: true, useSurfaceEnv: true},
	"wait":               {method: "browser.wait", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true, flagOverrides: map[string]string{"text": "text_contains", "url": "url_contains"}, special: browserSpecialWait},
	"click":              {method: "browser.click", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"dblclick":           {method: "browser.dblclick", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"hover":              {method: "browser.hover", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"focus":              {method: "browser.focus", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"check":              {method: "browser.check", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"uncheck":            {method: "browser.uncheck", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"scroll-into-view":   {method: "browser.scroll_into_view", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"scrollinto":         {method: "browser.scroll_into_view", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"scrollintoview":     {method: "browser.scroll_into_view", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"type":               {method: "browser.type", positionalKeys: []string{"selector", "text"}, joinLast: true, useSurfaceEnv: true},
	"fill":               {method: "browser.fill", positionalKeys: []string{"selector", "text"}, joinLast: true, useSurfaceEnv: true},
	"press":              {method: "browser.press", positionalKeys: []string{"key"}, joinLast: true, useSurfaceEnv: true},
	"key":                {method: "browser.press", positionalKeys: []string{"key"}, joinLast: true, useSurfaceEnv: true},
	"keydown":            {method: "browser.keydown", positionalKeys: []string{"key"}, joinLast: true, useSurfaceEnv: true},
	"keyup":              {method: "browser.keyup", positionalKeys: []string{"key"}, joinLast: true, useSurfaceEnv: true},
	"select":             {method: "browser.select", positionalKeys: []string{"selector", "value"}, joinLast: true, useSurfaceEnv: true},
	"scroll":             {method: "browser.scroll", positionalKeys: []string{"dy"}, useSurfaceEnv: true},
	"screenshot":         {method: "browser.screenshot", useSurfaceEnv: true, special: browserSpecialScreenshot},

	"get url":          {method: "browser.url.get", useSurfaceEnv: true},
	"get title":        {method: "browser.get.title", useSurfaceEnv: true},
	"get text":         {method: "browser.get.text", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"get html":         {method: "browser.get.html", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"get value":        {method: "browser.get.value", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"get attr":         {method: "browser.get.attr", positionalKeys: []string{"selector", "attr"}, useSurfaceEnv: true},
	"get count":        {method: "browser.get.count", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"get box":          {method: "browser.get.box", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"get styles":       {method: "browser.get.styles", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"is visible":       {method: "browser.is.visible", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"is enabled":       {method: "browser.is.enabled", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"is checked":       {method: "browser.is.checked", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"find role":        {method: "browser.find.role", positionalKeys: []string{"role"}, useSurfaceEnv: true},
	"find text":        {method: "browser.find.text", positionalKeys: []string{"text"}, joinLast: true, useSurfaceEnv: true},
	"find label":       {method: "browser.find.label", positionalKeys: []string{"label"}, joinLast: true, useSurfaceEnv: true},
	"find placeholder": {method: "browser.find.placeholder", positionalKeys: []string{"placeholder"}, joinLast: true, useSurfaceEnv: true},
	"find alt":         {method: "browser.find.alt", positionalKeys: []string{"alt"}, joinLast: true, useSurfaceEnv: true},
	"find title":       {method: "browser.find.title", positionalKeys: []string{"title"}, joinLast: true, useSurfaceEnv: true},
	"find testid":      {method: "browser.find.testid", positionalKeys: []string{"testid"}, useSurfaceEnv: true},
	"find first":       {method: "browser.find.first", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"find last":        {method: "browser.find.last", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"find nth":         {method: "browser.find.nth", positionalKeys: []string{"index", "selector"}, useSurfaceEnv: true, special: browserSpecialFindNth},

	"frame":          {method: "browser.frame.select", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"frame select":   {method: "browser.frame.select", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"frame main":     {method: "browser.frame.main", useSurfaceEnv: true},
	"dialog accept":  {method: "browser.dialog.accept", positionalKeys: []string{"text"}, joinLast: true, useSurfaceEnv: true},
	"dialog dismiss": {method: "browser.dialog.dismiss", useSurfaceEnv: true},
	"download":       {method: "browser.download.wait", positionalKeys: []string{"path"}, useSurfaceEnv: true, special: browserSpecialWait},
	"download wait":  {method: "browser.download.wait", positionalKeys: []string{"path"}, useSurfaceEnv: true, special: browserSpecialWait},

	"cookies":       {method: "browser.cookies.get", useSurfaceEnv: true},
	"cookies get":   {method: "browser.cookies.get", useSurfaceEnv: true},
	"cookies set":   {method: "browser.cookies.set", positionalKeys: []string{"name", "value"}, useSurfaceEnv: true},
	"cookies clear": {method: "browser.cookies.clear", useSurfaceEnv: true},

	"storage local":         {method: "browser.storage.get", defaultParams: map[string]any{"type": "local"}, positionalKeys: []string{"key"}, useSurfaceEnv: true},
	"storage local get":     {method: "browser.storage.get", defaultParams: map[string]any{"type": "local"}, positionalKeys: []string{"key"}, useSurfaceEnv: true},
	"storage local set":     {method: "browser.storage.set", defaultParams: map[string]any{"type": "local"}, positionalKeys: []string{"key", "value"}, joinLast: true, useSurfaceEnv: true},
	"storage local clear":   {method: "browser.storage.clear", defaultParams: map[string]any{"type": "local"}, useSurfaceEnv: true},
	"storage session":       {method: "browser.storage.get", defaultParams: map[string]any{"type": "session"}, positionalKeys: []string{"key"}, useSurfaceEnv: true},
	"storage session get":   {method: "browser.storage.get", defaultParams: map[string]any{"type": "session"}, positionalKeys: []string{"key"}, useSurfaceEnv: true},
	"storage session set":   {method: "browser.storage.set", defaultParams: map[string]any{"type": "session"}, positionalKeys: []string{"key", "value"}, joinLast: true, useSurfaceEnv: true},
	"storage session clear": {method: "browser.storage.clear", defaultParams: map[string]any{"type": "session"}, useSurfaceEnv: true},

	"tab":           {method: "browser.tab.list", useSurfaceEnv: true},
	"tab list":      {method: "browser.tab.list", useSurfaceEnv: true},
	"tab new":       {method: "browser.tab.new", positionalKeys: []string{"url"}, joinLast: true, useSurfaceEnv: true},
	"tab switch":    {method: "browser.tab.switch", positionalKeys: []string{"target_surface_id"}, useSurfaceEnv: true, special: browserSpecialTabTarget},
	"tab close":     {method: "browser.tab.close", positionalKeys: []string{"target_surface_id"}, useSurfaceEnv: true, special: browserSpecialTabTarget},
	"console":       {method: "browser.console.list", useSurfaceEnv: true},
	"console list":  {method: "browser.console.list", useSurfaceEnv: true},
	"console clear": {method: "browser.console.clear", useSurfaceEnv: true},
	"errors":        {method: "browser.errors.list", useSurfaceEnv: true},
	"errors list":   {method: "browser.errors.list", useSurfaceEnv: true},
	// The app exposes browser.errors.list only; clearing is a list request with clear=true.
	"errors clear":  {method: "browser.errors.list", defaultParams: map[string]any{"clear": true}, useSurfaceEnv: true},
	"highlight":     {method: "browser.highlight", positionalKeys: []string{"selector"}, joinLast: true, useSurfaceEnv: true},
	"state save":    {method: "browser.state.save", positionalKeys: []string{"path"}, useSurfaceEnv: true},
	"state load":    {method: "browser.state.load", positionalKeys: []string{"path"}, useSurfaceEnv: true},
	"addinitscript": {method: "browser.addinitscript", positionalKeys: []string{"script"}, joinLast: true, useSurfaceEnv: true},
	"addscript":     {method: "browser.addscript", positionalKeys: []string{"script"}, joinLast: true, useSurfaceEnv: true},
	"addstyle":      {method: "browser.addstyle", positionalKeys: []string{"css"}, joinLast: true, useSurfaceEnv: true, flagOverrides: map[string]string{"style": "css", "content": "css"}},

	"viewport":         {method: "browser.viewport.set", positionalKeys: []string{"width", "height"}, useSurfaceEnv: true},
	"viewport set":     {method: "browser.viewport.set", positionalKeys: []string{"width", "height"}, useSurfaceEnv: true},
	"geolocation":      {method: "browser.geolocation.set", positionalKeys: []string{"latitude", "longitude"}, useSurfaceEnv: true},
	"geo":              {method: "browser.geolocation.set", positionalKeys: []string{"latitude", "longitude"}, useSurfaceEnv: true},
	"offline":          {method: "browser.offline.set", positionalKeys: []string{"enabled"}, useSurfaceEnv: true},
	"trace start":      {method: "browser.trace.start", positionalKeys: []string{"path"}, useSurfaceEnv: true},
	"trace stop":       {method: "browser.trace.stop", positionalKeys: []string{"path"}, useSurfaceEnv: true},
	"network route":    {method: "browser.network.route", positionalKeys: []string{"url"}, useSurfaceEnv: true},
	"network unroute":  {method: "browser.network.unroute", positionalKeys: []string{"url"}, useSurfaceEnv: true},
	"network requests": {method: "browser.network.requests", useSurfaceEnv: true},
	"screencast start": {method: "browser.screencast.start", useSurfaceEnv: true},
	"screencast stop":  {method: "browser.screencast.stop", useSurfaceEnv: true},
	"input mouse":      {method: "browser.input_mouse", useSurfaceEnv: true, special: browserSpecialInputArgs},
	"input keyboard":   {method: "browser.input_keyboard", useSurfaceEnv: true, special: browserSpecialInputArgs},
	"input touch":      {method: "browser.input_touch", useSurfaceEnv: true, special: browserSpecialInputArgs},
	"input-mouse":      {method: "browser.input_mouse", useSurfaceEnv: true, special: browserSpecialInputArgs},
	"input-keyboard":   {method: "browser.input_keyboard", useSurfaceEnv: true, special: browserSpecialInputArgs},
	"input-touch":      {method: "browser.input_touch", useSurfaceEnv: true, special: browserSpecialInputArgs},
}

var commandIndex map[string]*commandSpec

func init() {
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
	var browserReq browserRelayRequest
	if cmdName == "browser" {
		if browserHelpRequested(cmdArgs) {
			browserUsage(os.Stdout)
			return 0
		}
		var err error
		browserReq, err = buildBrowserRelayRequest(cmdArgs)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux browser: %v\n", err)
			return 2
		}
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

	// Browser subcommand delegation
	if cmdName == "browser" {
		return runBrowserRelay(socketPath, browserReq, jsonOutput, refreshAddr)
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

	switch spec.proto {
	case protoV1:
		return execV1(socketPath, spec, cmdArgs, refreshAddr)
	case protoV2:
		return execV2(socketPath, spec, cmdArgs, jsonOutput, refreshAddr)
	default:
		fmt.Fprintf(os.Stderr, "cmux: internal error: unknown protocol for %q\n", cmdName)
		return 1
	}
}

// execV1 sends a v1 text command over the socket.
func execV1(socketPath string, spec *commandSpec, args []string, refreshAddr func() string) int {
	cmd := spec.v1Cmd

	if !spec.noParams {
		parsed, err := parseFlags(args, spec.flagKeys)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
			return 2
		}
		for _, key := range spec.flagKeys {
			if val, ok := parsed.flags[key]; ok {
				cmd += " " + val
			}
		}
	}

	resp, err := socketRoundTrip(socketPath, cmd, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	fmt.Print(resp)
	if !strings.HasSuffix(resp, "\n") {
		fmt.Println()
	}
	return 0
}

// execV2 sends a v2 JSON-RPC request over the socket.
func execV2(socketPath string, spec *commandSpec, args []string, jsonOutput bool, refreshAddr func() string) int {
	params := make(map[string]any, len(spec.defaultParams))
	for key, value := range spec.defaultParams {
		params[key] = value
	}

	if !spec.noParams {
		parsed, err := parseFlags(args, spec.flagKeys)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
			return 2
		}
		// Map flag keys to JSON param keys (e.g. "workspace" → "workspace_id" where appropriate)
		for _, key := range spec.flagKeys {
			if val, ok := parsed.flags[key]; ok {
				paramKey := flagToParamKey(key)
				if override, ok := spec.paramKeyOverrides[key]; ok {
					paramKey = override
				}
				params[paramKey] = val
			}
		}

		// First positional arg is used as initial_command if --command wasn't given
		if _, ok := params["initial_command"]; !ok && len(parsed.positional) > 0 {
			params["initial_command"] = parsed.positional[0]
		}

		applyWorkspaceEnvFallback(params)
		applySurfaceEnvFallback(params)
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

// runBrowserRelay sends a parsed "cmux browser <subcommand>" request as a browser.* v2 method.
func runBrowserRelay(socketPath string, req browserRelayRequest, jsonOutput bool, refreshAddr func() string) int {
	resp, err := socketRoundTripV2(socketPath, req.spec.method, req.params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	return printBrowserRelayResponse(req.spec, resp, jsonOutput || req.parsed.localJSON, req.parsed.outPath)
}

type browserRelayRequest struct {
	spec   browserCommandSpec
	params map[string]any
	parsed browserParsedArgs
}

type browserParsedArgs struct {
	flags      map[string]any
	positional []string
	localJSON  bool
	outPath    string
}

func buildBrowserRelayRequest(args []string) (browserRelayRequest, error) {
	if len(args) == 0 {
		return browserRelayRequest{}, fmt.Errorf("requires a subcommand (%s)", browserSubcommandHint())
	}

	leadingParams := map[string]any{}
	leadingParamSources := map[string]string{}
	localJSON := false
	for len(args) > 0 {
		switch normalizeBrowserToken(args[0]) {
		case "--json":
			localJSON = true
			args = args[1:]
			continue
		case "--surface":
			if len(args) < 2 {
				return browserRelayRequest{}, fmt.Errorf("--surface requires a value")
			}
			leadingParams["surface_id"] = args[1]
			leadingParamSources["surface_id"] = "--surface"
			args = args[2:]
			continue
		case "--workspace":
			if len(args) < 2 {
				return browserRelayRequest{}, fmt.Errorf("--workspace requires a value")
			}
			leadingParams["workspace_id"] = args[1]
			leadingParamSources["workspace_id"] = "--workspace"
			args = args[2:]
			continue
		case "--window":
			if len(args) < 2 {
				return browserRelayRequest{}, fmt.Errorf("--window requires a value")
			}
			leadingParams["window_id"] = args[1]
			leadingParamSources["window_id"] = "--window"
			args = args[2:]
			continue
		case "--pane":
			if len(args) < 2 {
				return browserRelayRequest{}, fmt.Errorf("--pane requires a value")
			}
			leadingParams["pane_id"] = args[1]
			leadingParamSources["pane_id"] = "--pane"
			args = args[2:]
			continue
		}
		if isBrowserSurfaceTarget(args[0]) {
			leadingParams["surface_id"] = args[0]
			leadingParamSources["surface_id"] = "surface target"
			args = args[1:]
			continue
		}
		break
	}

	commandKey, spec, consumed, interleavedFlags, ok := resolveBrowserCommand(args)
	if !ok {
		if len(args) == 0 {
			return browserRelayRequest{}, fmt.Errorf("requires a subcommand (%s)", browserSubcommandHint())
		}
		return browserRelayRequest{}, fmt.Errorf("unknown subcommand %q", args[0])
	}

	parseArgs := args[consumed:]
	if len(interleavedFlags) > 0 {
		parseArgs = append(append([]string{}, interleavedFlags...), parseArgs...)
	}
	parsed, err := parseBrowserArgs(parseArgs)
	if err != nil {
		return browserRelayRequest{}, err
	}
	parsed.localJSON = parsed.localJSON || localJSON
	if parsed.outPath != "" && spec.special != browserSpecialScreenshot {
		return browserRelayRequest{}, fmt.Errorf("--out is only supported for browser screenshot")
	}

	params := make(map[string]any, len(spec.defaultParams)+len(leadingParams)+len(parsed.flags))
	for key, value := range spec.defaultParams {
		params[key] = value
	}
	paramSources := map[string]string{}
	for key, value := range leadingParams {
		params[key] = value
		if source, ok := leadingParamSources[key]; ok {
			paramSources[key] = source
		}
	}
	flagKeys := make([]string, 0, len(parsed.flags))
	for key := range parsed.flags {
		flagKeys = append(flagKeys, key)
	}
	sort.Strings(flagKeys)
	for _, key := range flagKeys {
		value := parsed.flags[key]
		paramKey := browserParamKeyForFlag(key, spec)
		source := "--" + key
		if previous, ok := paramSources[paramKey]; ok && previous != source {
			return browserRelayRequest{}, fmt.Errorf("conflicting browser options %s and %s both set %s", previous, source, paramKey)
		}
		paramSources[paramKey] = source
		params[paramKey] = value
	}
	if browserOpenCommandShouldNavigate(commandKey, params) {
		spec = browserCommands["navigate"]
	}

	if err := applyBrowserPositionals(params, parsed.positional, spec); err != nil {
		return browserRelayRequest{}, err
	}
	if err := applyBrowserSpecialParams(params, spec); err != nil {
		return browserRelayRequest{}, err
	}
	if spec.useWorkspaceEnv {
		applyWorkspaceEnvFallback(params)
	}
	if spec.useSurfaceEnv {
		applySurfaceEnvFallback(params)
	}
	return browserRelayRequest{spec: spec, params: params, parsed: parsed}, nil
}

func resolveBrowserCommand(args []string) (string, browserCommandSpec, int, []string, bool) {
	if len(args) == 0 {
		return "", browserCommandSpec{}, 0, nil, false
	}
	if normalizeBrowserToken(args[0]) == "tab" {
		for idx := 1; idx < len(args); idx++ {
			if isBrowserShortBooleanFlag(args[idx]) {
				continue
			}
			second := normalizeBrowserToken(args[idx])
			if strings.HasPrefix(args[idx], "--") {
				break
			}
			if second != "new" && second != "list" && second != "switch" && second != "close" && (second == "-" || isIntegerString(second) || !strings.HasPrefix(second, "-")) {
				spec := browserCommands["tab switch"]
				return "tab switch", spec, 1, nil, true
			}
			break
		}
	}

	commandTokenIndices := make([]int, 0, 3)
	for idx := 0; idx < len(args) && len(commandTokenIndices) < 3; idx++ {
		if strings.HasPrefix(args[idx], "--") {
			break
		}
		if isBrowserShortBooleanFlag(args[idx]) {
			continue
		}
		commandTokenIndices = append(commandTokenIndices, idx)
	}
	for count := len(commandTokenIndices); count >= 1; count-- {
		tokens := make([]string, 0, count)
		for _, idx := range commandTokenIndices[:count] {
			tokens = append(tokens, args[idx])
		}
		key := browserCommandKey(tokens)
		if spec, ok := browserCommands[key]; ok {
			consumed := commandTokenIndices[count-1] + 1
			interleavedFlags := make([]string, 0)
			for _, arg := range args[:consumed] {
				if isBrowserShortBooleanFlag(arg) {
					interleavedFlags = append(interleavedFlags, arg)
				}
			}
			return key, spec, consumed, interleavedFlags, true
		}
	}
	return "", browserCommandSpec{}, 0, nil, false
}

func browserCommandKey(tokens []string) string {
	normalized := make([]string, 0, len(tokens))
	for _, token := range tokens {
		normalized = append(normalized, normalizeBrowserToken(token))
	}
	return strings.Join(normalized, " ")
}

func normalizeBrowserToken(token string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(token)), "_", "-")
}

func isBrowserSurfaceTarget(token string) bool {
	trimmed := strings.TrimSpace(token)
	lower := strings.ToLower(trimmed)
	for _, prefix := range []string{"surface:", "tab:"} {
		if strings.HasPrefix(lower, prefix) {
			return strings.TrimSpace(trimmed[len(prefix):]) != ""
		}
	}
	return looksLikeUUID(lower)
}

func looksLikeUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, r := range value {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
				return false
			}
		}
	}
	return true
}

func parseBrowserArgs(args []string) (browserParsedArgs, error) {
	parsed := browserParsedArgs{flags: map[string]any{}}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			parsed.positional = append(parsed.positional, args[i+1:]...)
			break
		}
		if arg == "-i" {
			parsed.flags["interactive"] = true
			continue
		}
		if arg == "-y" {
			parsed.flags["yes"] = true
			continue
		}
		if !strings.HasPrefix(arg, "--") {
			parsed.positional = append(parsed.positional, arg)
			continue
		}
		raw := strings.TrimPrefix(arg, "--")
		key, value, hasInlineValue := strings.Cut(raw, "=")
		if key == "" {
			return browserParsedArgs{}, fmt.Errorf("empty flag")
		}
		if key == "json" {
			parsed.localJSON = true
			continue
		}
		var parsedValue any
		if hasInlineValue {
			parsedValue = value
		} else if browserFlagIsBoolean(key) {
			parsedValue = true
		} else if i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") && !isBrowserShortBooleanFlag(args[i+1]) {
			parsedValue = args[i+1]
			i++
		} else {
			parsedValue = true
		}
		switch key {
		case "out":
			outPath, ok := parsedValue.(string)
			if !ok || strings.TrimSpace(outPath) == "" {
				return browserParsedArgs{}, fmt.Errorf("--out requires a path")
			}
			parsed.outPath = outPath
		default:
			parsed.flags[key] = parsedValue
		}
	}
	return parsed, nil
}

func isBrowserShortBooleanFlag(arg string) bool {
	switch arg {
	case "-i", "-y":
		return true
	default:
		return false
	}
}

func browserFlagIsBoolean(key string) bool {
	switch key {
	case "snapshot-after", "interactive", "cursor", "compact", "exact", "secure", "all", "force", "yes",
		"non-interactive", "noninteractive", "all-profiles", "create-profile", "create-destination-profile",
		"abort":
		return true
	default:
		return false
	}
}

func applyBrowserPositionals(params map[string]any, positionals []string, spec browserCommandSpec) error {
	switch spec.special {
	case browserSpecialFindNth:
		positionalIndex := 0
		if _, ok := params["index"]; !ok && positionalIndex < len(positionals) {
			params["index"] = positionals[positionalIndex]
			positionalIndex++
		}
		if _, ok := params["selector"]; !ok {
			if positionalIndex < len(positionals) {
				params["selector"] = strings.Join(positionals[positionalIndex:], " ")
			}
			return nil
		}
		if positionalIndex < len(positionals) {
			return fmt.Errorf("unrecognized extra positional argument %q", positionals[positionalIndex])
		}
		return nil
	case browserSpecialTabTarget:
		if len(positionals) == 0 {
			return nil
		}
		if _, ok := params["target_surface_id"]; ok {
			return fmt.Errorf("unrecognized extra positional argument %q", positionals[0])
		}
		if _, ok := params["index"]; ok {
			return fmt.Errorf("unrecognized extra positional argument %q", positionals[0])
		}
		if isIntegerString(positionals[0]) {
			params["index"] = positionals[0]
		} else {
			params["target_surface_id"] = positionals[0]
		}
		if len(positionals) > 1 {
			return fmt.Errorf("unrecognized extra positional argument %q", positionals[1])
		}
		return nil
	case browserSpecialInputArgs:
		if len(positionals) > 0 {
			params["args"] = append([]string(nil), positionals...)
		}
		return nil
	}

	positionalIndex := 0
	joinedRemainingPositionals := false
	for idx, key := range spec.positionalKeys {
		if _, ok := params[key]; ok {
			continue
		}
		if positionalIndex >= len(positionals) {
			continue
		}
		value := positionals[positionalIndex]
		if spec.joinLast && idx == len(spec.positionalKeys)-1 {
			value = strings.Join(positionals[positionalIndex:], " ")
			joinedRemainingPositionals = true
		}
		params[key] = value
		if joinedRemainingPositionals {
			positionalIndex = len(positionals)
		} else {
			positionalIndex++
		}
	}
	if positionalIndex < len(positionals) && (!spec.joinLast || !joinedRemainingPositionals) {
		return fmt.Errorf("unrecognized extra positional argument %q", positionals[positionalIndex])
	}
	return nil
}

func applyBrowserSpecialParams(params map[string]any, spec browserCommandSpec) error {
	if spec.special == browserSpecialWait {
		if timeout, ok := params["timeout"]; ok {
			seconds, parsed := parseNumberishString(timeout)
			if !parsed {
				return fmt.Errorf("--timeout must be a number of seconds")
			}
			if seconds < 0 {
				return fmt.Errorf("--timeout must be a non-negative number of seconds")
			}
			if _, hasTimeoutMs := params["timeout_ms"]; !hasTimeoutMs {
				params["timeout_ms"] = fmt.Sprintf("%d", int(seconds*1000))
			}
			delete(params, "timeout")
		}
	}
	return nil
}

func parseNumberishString(value any) (float64, bool) {
	switch typed := value.(type) {
	case string:
		trimmed := strings.TrimSpace(typed)
		if trimmed == "" {
			return 0, false
		}
		if parsed, err := strconv.ParseFloat(trimmed, 64); err == nil && !math.IsNaN(parsed) && !math.IsInf(parsed, 0) {
			return parsed, true
		}
	case int:
		return float64(typed), true
	case float64:
		return typed, true
	}
	return 0, false
}

func isIntegerString(value string) bool {
	if value == "" {
		return false
	}
	start := 0
	if value[0] == '-' || value[0] == '+' {
		start = 1
	}
	if start >= len(value) {
		return false
	}
	for _, r := range value[start:] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func printBrowserRelayResponse(spec browserCommandSpec, resp string, jsonOutput bool, outPath string) int {
	if spec.special == browserSpecialScreenshot && outPath != "" {
		return writeBrowserScreenshotOutput(resp, outPath, jsonOutput)
	}
	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

func browserSubcommandHint() string {
	seen := make(map[string]struct{}, len(browserCommands))
	names := make([]string, 0, len(browserCommands))
	for name := range browserCommands {
		topLevel := strings.Fields(name)[0]
		if _, ok := seen[topLevel]; ok {
			continue
		}
		seen[topLevel] = struct{}{}
		names = append(names, topLevel)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

func browserHelpRequested(args []string) bool {
	for len(args) > 0 && normalizeBrowserToken(args[0]) == "--json" {
		args = args[1:]
	}
	if len(args) == 0 {
		return false
	}
	switch normalizeBrowserToken(args[0]) {
	case "help", "--help", "-h":
		return true
	default:
		return false
	}
}

func browserOpenCommandShouldNavigate(commandKey string, params map[string]any) bool {
	switch commandKey {
	case "open", "open-split", "new":
	default:
		return false
	}
	surfaceID, ok := params["surface_id"].(string)
	return ok && strings.TrimSpace(surfaceID) != ""
}

func browserUsage(out io.Writer) {
	fmt.Fprintln(out, "Usage: cmux browser [--surface <id|ref> | <surface>] <subcommand> [args]")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Options: --out <path> is supported by browser screenshot only")
	fmt.Fprintf(out, "Subcommands: %s\n", browserSubcommandHint())
}

func writeBrowserScreenshotOutput(resp string, outPath string, jsonOutput bool) int {
	var result map[string]any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		fmt.Fprintf(os.Stderr, "cmux browser: invalid screenshot response: %v\n", err)
		return 1
	}
	b64, _ := result["png_base64"].(string)
	if strings.TrimSpace(b64) == "" {
		fmt.Fprintln(os.Stderr, "cmux browser: screenshot response missing png_base64")
		return 1
	}
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux browser: invalid screenshot image data: %v\n", err)
		return 1
	}
	resolvedPath := resolveBrowserOutputPath(outPath)
	if err := os.MkdirAll(filepath.Dir(resolvedPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "cmux browser: failed to create screenshot directory: %v\n", err)
		return 1
	}
	if err := os.WriteFile(resolvedPath, data, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "cmux browser: failed to write screenshot: %v\n", err)
		return 1
	}
	result["path"] = resolvedPath
	delete(result, "png_base64")
	if jsonOutput {
		encoded, err := json.Marshal(result)
		if err != nil {
			fmt.Println(resp)
		} else {
			fmt.Println(string(encoded))
		}
	} else {
		fmt.Println(resolvedPath)
	}
	return 0
}

func resolveBrowserOutputPath(path string) string {
	if path == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	return path
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
	case "panel":
		return "panel_id"
	case "command":
		return "initial_command"
	case "name":
		return "title"
	case "working-directory":
		return "working_directory"
	default:
		return commonFlagToParamKey(key)
	}
}

func browserFlagToParamKey(key string) string {
	switch key {
	case "panel":
		return "surface_id"
	default:
		return commonFlagToParamKey(key)
	}
}

func browserParamKeyForFlag(key string, spec browserCommandSpec) string {
	if override, ok := spec.flagOverrides[key]; ok {
		return override
	}
	return browserFlagToParamKey(key)
}

func commonFlagToParamKey(key string) string {
	switch key {
	case "workspace":
		return "workspace_id"
	case "surface":
		return "surface_id"
	case "pane":
		return "pane_id"
	case "window":
		return "window_id"
	default:
		return strings.ReplaceAll(key, "-", "_")
	}
}

// parsedFlags holds the results of flag parsing.
type parsedFlags struct {
	flags      map[string]string // --key value pairs
	positional []string          // non-flag arguments
}

// parseFlags extracts --key value pairs from args for the given allowed keys.
// Non-flag arguments are collected in positional.
func parseFlags(args []string, keys []string) (parsedFlags, error) {
	allowed := make(map[string]bool, len(keys))
	for _, k := range keys {
		allowed[k] = true
	}

	result := parsedFlags{flags: make(map[string]string)}
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
		result.flags[key] = args[i+1]
		i++
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

// socketRoundTrip sends a raw text line and reads a raw text response (v1).
func socketRoundTrip(socketPath, command string, refreshAddr func() string) (string, error) {
	conn, err := dialSocket(socketPath, refreshAddr)
	if err != nil {
		return "", fmt.Errorf("failed to connect to %s: %w", socketPath, err)
	}
	defer conn.Close()

	if _, err := fmt.Fprintf(conn, "%s\n", command); err != nil {
		return "", fmt.Errorf("failed to send command: %w", err)
	}

	// V1 handlers may return multiple lines (e.g. list_windows). Read until
	// the stream goes idle briefly after seeing at least one newline.
	reader := bufio.NewReader(conn)
	var response strings.Builder
	sawNewline := false

	for {
		readTimeout := 15 * time.Second
		if sawNewline {
			readTimeout = 120 * time.Millisecond
		}
		_ = conn.SetReadDeadline(time.Now().Add(readTimeout))

		chunk, err := reader.ReadString('\n')
		if chunk != "" {
			response.WriteString(chunk)
			if strings.Contains(chunk, "\n") {
				sawNewline = true
			}
		}

		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				if sawNewline {
					break
				}
				return "", fmt.Errorf("failed to read response: timeout waiting for response")
			}
			if errors.Is(err, io.EOF) {
				break
			}
			return "", fmt.Errorf("failed to read response: %w", err)
		}
	}

	return strings.TrimRight(response.String(), "\n"), nil
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
	fmt.Fprintln(os.Stderr, "  ping                     Check connectivity")
	fmt.Fprintln(os.Stderr, "  capabilities              List server capabilities")
	fmt.Fprintln(os.Stderr, "  list-workspaces           List all workspaces")
	fmt.Fprintln(os.Stderr, "  new-window                Create a new window")
	fmt.Fprintln(os.Stderr, "  new-workspace             Create a new workspace")
	fmt.Fprintln(os.Stderr, "  new-surface               Create a new surface")
	fmt.Fprintln(os.Stderr, "  new-split                 Split an existing surface")
	fmt.Fprintln(os.Stderr, "  close-surface             Close a surface")
	fmt.Fprintln(os.Stderr, "  close-workspace           Close a workspace")
	fmt.Fprintln(os.Stderr, "  select-workspace          Select a workspace")
	fmt.Fprintln(os.Stderr, "  send                      Send text to a surface")
	fmt.Fprintln(os.Stderr, "  send-key                  Send a key to a surface")
	fmt.Fprintln(os.Stderr, "  notify                    Create a notification")
	fmt.Fprintln(os.Stderr, "  browser <sub>             Browser commands through the local cmux browser relay; see 'cmux browser help'")
	fmt.Fprintln(os.Stderr, "  claude-teams [args...]     Launch Claude Code in teammate mode")
	fmt.Fprintln(os.Stderr, "  omo [args...]              Launch OpenCode with cmux integration")
	fmt.Fprintln(os.Stderr, "  omx [args...]              Launch Oh My Codex with cmux integration")
	fmt.Fprintln(os.Stderr, "  omc [args...]              Launch Oh My Claude Code with cmux integration")
	fmt.Fprintln(os.Stderr, "  rpc <method> [json-params] Send arbitrary JSON-RPC")
}
