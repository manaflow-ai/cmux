package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// runTmuxCompat handles `cmux __tmux-compat <args...>`, translating tmux
// commands into cmux JSON-RPC calls over the relay socket.
func runTmuxCompat(socketPath string, args []string, refreshAddr func() string) int {
	command, cmdArgs, err := splitTmuxCmd(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux __tmux-compat: %v\n", err)
		return 1
	}

	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}
	if err := dispatchTmuxCommand(rc, command, cmdArgs); err != nil {
		fmt.Fprintf(os.Stderr, "cmux __tmux-compat: %v\n", err)
		return 1
	}
	return 0
}

// rpcContext holds connection info for making JSON-RPC calls.
type rpcContext struct {
	socketPath  string
	refreshAddr func() string
}

// call makes a JSON-RPC call and returns the parsed result.
func (rc *rpcContext) call(method string, params map[string]any) (map[string]any, error) {
	resp, err := socketRoundTripV2(rc.socketPath, method, params, rc.refreshAddr)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		// Some responses are bare values (string, null)
		return nil, nil
	}
	return result, nil
}

// --- Tmux argument parsing ---

type tmuxParsed struct {
	flags      map[string]bool     // boolean flags like -d, -P
	options    map[string][]string // value flags like -t <target>
	positional []string
}

func (p *tmuxParsed) hasFlag(f string) bool {
	return p.flags[f]
}

func (p *tmuxParsed) value(f string) string {
	vals := p.options[f]
	if len(vals) == 0 {
		return ""
	}
	return vals[len(vals)-1]
}

func splitTmuxCmd(args []string) (string, []string, error) {
	globalValueFlags := map[string]bool{"-L": true, "-S": true, "-f": true}
	globalBoolFlags := map[string]bool{"-V": true, "-v": true}

	i := 0
	for i < len(args) {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			return strings.ToLower(arg), args[i+1:], nil
		}
		if arg == "--" {
			break
		}
		if globalBoolFlags[arg] {
			return arg, nil, nil
		}
		if globalValueFlags[arg] {
			// Skip the value
			i++
		}
		i++
	}
	return "", nil, fmt.Errorf("tmux shim requires a command")
}

func parseTmuxArgs(args []string, valueFlags, boolFlags []string) *tmuxParsed {
	vSet := make(map[string]bool, len(valueFlags))
	for _, f := range valueFlags {
		vSet[f] = true
	}
	bSet := make(map[string]bool, len(boolFlags))
	for _, f := range boolFlags {
		bSet[f] = true
	}

	p := &tmuxParsed{
		flags:   make(map[string]bool),
		options: make(map[string][]string),
	}
	pastTerminator := false

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if pastTerminator {
			p.positional = append(p.positional, arg)
			continue
		}
		if arg == "--" {
			pastTerminator = true
			continue
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			p.positional = append(p.positional, arg)
			continue
		}
		if strings.HasPrefix(arg, "--") {
			p.positional = append(p.positional, arg)
			continue
		}

		// Cluster parsing: -dPh etc.
		cluster := []rune(arg[1:])
		cursor := 0
		recognized := false
		for cursor < len(cluster) {
			flag := "-" + string(cluster[cursor])
			if bSet[flag] {
				p.flags[flag] = true
				cursor++
				recognized = true
				continue
			}
			if vSet[flag] {
				remainder := string(cluster[cursor+1:])
				var value string
				if remainder != "" {
					value = remainder
				} else if i+1 < len(args) {
					i++
					value = args[i]
				}
				p.options[flag] = append(p.options[flag], value)
				recognized = true
				cursor = len(cluster)
				continue
			}
			recognized = false
			break
		}
		if !recognized {
			p.positional = append(p.positional, arg)
		}
	}
	return p
}

// --- Format string rendering ---

var tmuxFormatVarRe = regexp.MustCompile(`#\{[^}]+\}`)

func tmuxRenderFormat(format string, context map[string]string, fallback string) string {
	if format == "" {
		return fallback
	}
	rendered := format
	for key, value := range context {
		rendered = strings.ReplaceAll(rendered, "#{"+key+"}", value)
	}
	// Remove any remaining unresolved #{...} variables
	rendered = tmuxFormatVarRe.ReplaceAllString(rendered, "")
	rendered = strings.TrimSpace(rendered)
	if rendered == "" {
		return fallback
	}
	return rendered
}

// --- Format context building ---

func tmuxFormatContext(rc *rpcContext, workspaceId string, paneId string, surfaceId string) (map[string]string, error) {
	canonicalWsId, err := tmuxResolveWorkspaceId(rc, workspaceId)
	if err != nil {
		return nil, err
	}

	ctx := map[string]string{
		"session_name":  "cmux",
		"session_id":    "$0",
		"window_id":     "@" + canonicalWsId,
		"window_uuid":   canonicalWsId,
		"window_active": "1",
		"window_flags":  "*",
		"pane_active":   "1",
	}

	// Get workspace list for index/title
	workspaces, err := tmuxWorkspaceItems(rc)
	if err == nil {
		for _, ws := range workspaces {
			wsId, _ := ws["id"].(string)
			wsRef, _ := ws["ref"].(string)
			if wsId == canonicalWsId || wsRef == workspaceId {
				if idx := intFromAnyGo(ws["index"]); idx >= 0 {
					ctx["window_index"] = fmt.Sprintf("%d", idx)
				}
				if title, _ := ws["title"].(string); strings.TrimSpace(title) != "" {
					ctx["window_name"] = strings.TrimSpace(title)
				}
				if paneCount := intFromAnyGo(ws["pane_count"]); paneCount >= 0 {
					ctx["window_panes"] = fmt.Sprintf("%d", paneCount)
				}
				break
			}
		}
	}

	// Get current surface info
	currentPayload, err := rc.call("surface.current", map[string]any{"workspace_id": canonicalWsId})
	if err != nil {
		return ctx, nil
	}

	resolvedPaneId := paneId
	if resolvedPaneId == "" {
		if pid, ok := currentPayload["pane_id"].(string); ok {
			resolvedPaneId = pid
		} else if pref, ok := currentPayload["pane_ref"].(string); ok {
			resolvedPaneId = pref
		}
	}

	resolvedSurfaceId := surfaceId
	if resolvedSurfaceId == "" && resolvedPaneId != "" {
		if sid, err := tmuxSelectedSurfaceId(rc, canonicalWsId, resolvedPaneId); err == nil {
			resolvedSurfaceId = sid
		}
	}
	if resolvedSurfaceId == "" {
		if sid, ok := currentPayload["surface_id"].(string); ok {
			resolvedSurfaceId = sid
		}
	}

	if resolvedPaneId != "" {
		ctx["pane_id"] = "%" + resolvedPaneId
		ctx["pane_uuid"] = resolvedPaneId

		panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": canonicalWsId})
		if err == nil {
			panes, _ := panePayload["panes"].([]any)
			for _, p := range panes {
				pane, _ := p.(map[string]any)
				if pane == nil {
					continue
				}
				if pid, _ := pane["id"].(string); pid == resolvedPaneId {
					if idx := intFromAnyGo(pane["index"]); idx >= 0 {
						ctx["pane_index"] = fmt.Sprintf("%d", idx)
					}
					break
				}
			}
		}
	}

	if resolvedSurfaceId != "" {
		ctx["surface_id"] = resolvedSurfaceId
		surfacePayload, err := rc.call("surface.list", map[string]any{"workspace_id": canonicalWsId})
		if err == nil {
			surfaces, _ := surfacePayload["surfaces"].([]any)
			for _, s := range surfaces {
				surface, _ := s.(map[string]any)
				if surface == nil {
					continue
				}
				if sid, _ := surface["id"].(string); sid == resolvedSurfaceId {
					if title, _ := surface["title"].(string); strings.TrimSpace(title) != "" {
						ctx["pane_title"] = strings.TrimSpace(title)
						if _, ok := ctx["window_name"]; !ok {
							ctx["window_name"] = strings.TrimSpace(title)
						}
					}
					break
				}
			}
		}
	}

	return ctx, nil
}

func tmuxEnrichContextWithGeometry(ctx map[string]string, pane map[string]any, containerFrame map[string]any) {
	isFocused, _ := pane["focused"].(bool)
	if isFocused {
		ctx["pane_active"] = "1"
	} else {
		ctx["pane_active"] = "0"
	}

	columns := intFromAnyGo(pane["columns"])
	rows := intFromAnyGo(pane["rows"])
	if columns < 0 || rows < 0 {
		return
	}
	ctx["pane_width"] = fmt.Sprintf("%d", columns)
	ctx["pane_height"] = fmt.Sprintf("%d", rows)

	cellW := intFromAnyGo(pane["cell_width_px"])
	cellH := intFromAnyGo(pane["cell_height_px"])
	if cellW <= 0 || cellH <= 0 {
		return
	}

	if frame, ok := pane["pixel_frame"].(map[string]any); ok {
		px := floatFromAny(frame["x"])
		py := floatFromAny(frame["y"])
		ctx["pane_left"] = fmt.Sprintf("%d", int(px)/cellW)
		ctx["pane_top"] = fmt.Sprintf("%d", int(py)/cellH)
	}

	if containerFrame != nil {
		cw := floatFromAny(containerFrame["width"])
		ch := floatFromAny(containerFrame["height"])
		ww := int(cw) / cellW
		wh := int(ch) / cellH
		if ww < 1 {
			ww = 1
		}
		if wh < 1 {
			wh = 1
		}
		ctx["window_width"] = fmt.Sprintf("%d", ww)
		ctx["window_height"] = fmt.Sprintf("%d", wh)
	}
}

func floatFromAny(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case int:
		return float64(t)
	case json.Number:
		f, _ := t.Float64()
		return f
	}
	return 0
}

func intFromAnyGo(v any) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case json.Number:
		i, err := t.Int64()
		if err != nil {
			return -1
		}
		return int(i)
	}
	return -1
}

// --- Target resolution ---

func tmuxCallerWorkspaceHandle() string {
	return strings.TrimSpace(os.Getenv("CMUX_WORKSPACE_ID"))
}

func tmuxCallerSurfaceHandle() string {
	return strings.TrimSpace(os.Getenv("CMUX_SURFACE_ID"))
}

func tmuxResolvedCallerWorkspaceId(rc *rpcContext) string {
	caller := tmuxCallerWorkspaceHandle()
	if caller == "" {
		return ""
	}
	wsId, err := tmuxResolveWorkspaceId(rc, caller)
	if err != nil {
		return ""
	}
	return wsId
}

func tmuxCallerPaneHandle() string {
	for _, key := range []string{"TMUX_PANE", "CMUX_PANE_ID"} {
		v := strings.TrimSpace(os.Getenv(key))
		if v != "" {
			return strings.TrimPrefix(v, "%")
		}
	}
	return ""
}

func tmuxWorkspaceItems(rc *rpcContext) ([]map[string]any, error) {
	payload, err := rc.call("workspace.list", nil)
	if err != nil {
		return nil, err
	}
	items, _ := payload["workspaces"].([]any)
	var result []map[string]any
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			result = append(result, m)
		}
	}
	return result, nil
}

func isUUIDish(s string) bool {
	// Simple UUID check: 8-4-4-4-12 hex
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

func tmuxResolveWorkspaceId(rc *rpcContext, raw string) (string, error) {
	if raw == "" || raw == "current" {
		if caller := tmuxCallerWorkspaceHandle(); caller != "" {
			if isUUIDish(caller) {
				return caller, nil
			}
			// Resolve ref
			return tmuxResolveWorkspaceId(rc, caller)
		}
		payload, err := rc.call("workspace.current", nil)
		if err != nil {
			return "", fmt.Errorf("no workspace selected: %w", err)
		}
		if wsId, ok := payload["workspace_id"].(string); ok {
			return wsId, nil
		}
		return "", fmt.Errorf("no workspace selected")
	}

	if isUUIDish(raw) {
		return raw, nil
	}

	// Try to resolve as ref or index
	items, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return "", err
	}
	for _, item := range items {
		if ref, _ := item["ref"].(string); ref == raw {
			if id, _ := item["id"].(string); id != "" {
				return id, nil
			}
		}
	}

	// Try name match
	needle := strings.TrimSpace(raw)
	for _, item := range items {
		title, _ := item["title"].(string)
		if strings.TrimSpace(title) == needle {
			if id, _ := item["id"].(string); id != "" {
				return id, nil
			}
		}
	}

	return "", fmt.Errorf("workspace not found: %s", raw)
}

func tmuxResolveWorkspaceTarget(rc *rpcContext, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		if caller := tmuxCallerWorkspaceHandle(); caller != "" {
			return tmuxResolveWorkspaceId(rc, caller)
		}
		return tmuxResolveWorkspaceId(rc, "")
	}

	if raw == "!" || raw == "^" || raw == "-" {
		payload, err := rc.call("workspace.last", nil)
		if err != nil {
			return "", fmt.Errorf("previous workspace not found: %w", err)
		}
		if wsId, ok := payload["workspace_id"].(string); ok {
			return wsId, nil
		}
		return "", fmt.Errorf("previous workspace not found")
	}

	// Strip session:window.pane format
	token := raw
	if dot := strings.LastIndex(token, "."); dot >= 0 {
		token = token[:dot]
	}
	if colon := strings.LastIndex(token, ":"); colon >= 0 {
		suffix := token[colon+1:]
		if suffix != "" {
			token = suffix
		} else {
			token = token[:colon]
		}
	}
	token = strings.TrimPrefix(token, "@")

	return tmuxResolveWorkspaceId(rc, token)
}

func tmuxPaneSelector(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "%") {
		return raw[1:]
	}
	if strings.HasPrefix(raw, "pane:") {
		return raw
	}
	if dot := strings.LastIndex(raw, "."); dot >= 0 {
		return raw[dot+1:]
	}
	return ""
}

func tmuxWindowSelector(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "%") || strings.HasPrefix(raw, "pane:") {
		return ""
	}
	if dot := strings.LastIndex(raw, "."); dot >= 0 {
		return raw[:dot]
	}
	return raw
}

func tmuxCanonicalPaneId(rc *rpcContext, handle string, workspaceId string) (string, error) {
	if isUUIDish(handle) {
		return handle, nil
	}
	payload, err := rc.call("pane.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	panes, _ := payload["panes"].([]any)
	for _, p := range panes {
		pane, _ := p.(map[string]any)
		if pane == nil {
			continue
		}
		if ref, _ := pane["ref"].(string); ref == handle {
			if id, _ := pane["id"].(string); id != "" {
				return id, nil
			}
		}
		if id, _ := pane["id"].(string); id == handle {
			return id, nil
		}
	}
	return "", fmt.Errorf("pane not found: %s", handle)
}

func tmuxCanonicalSurfaceId(rc *rpcContext, handle string, workspaceId string) (string, error) {
	payload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	surfaces, _ := payload["surfaces"].([]any)
	for _, s := range surfaces {
		surface, _ := s.(map[string]any)
		if surface == nil {
			continue
		}
		if ref, _ := surface["ref"].(string); ref == handle {
			if id, _ := surface["id"].(string); id != "" {
				return id, nil
			}
		}
		if id, _ := surface["id"].(string); id == handle {
			return id, nil
		}
	}
	return "", fmt.Errorf("surface not found: %s", handle)
}

func tmuxFocusedPaneId(rc *rpcContext, workspaceId string) (string, error) {
	payload, err := rc.call("surface.current", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	if pid, ok := payload["pane_id"].(string); ok {
		return pid, nil
	}
	if pref, ok := payload["pane_ref"].(string); ok {
		return tmuxCanonicalPaneId(rc, pref, workspaceId)
	}
	return "", fmt.Errorf("pane not found")
}

func tmuxWorkspaceIdForPaneHandle(rc *rpcContext, handle string) (string, error) {
	if !isUUIDish(handle) {
		return "", fmt.Errorf("not a UUID")
	}
	workspaces, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return "", err
	}
	for _, ws := range workspaces {
		wsId, _ := ws["id"].(string)
		if wsId == "" {
			continue
		}
		payload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
		if err != nil {
			continue
		}
		panes, _ := payload["panes"].([]any)
		for _, p := range panes {
			pane, _ := p.(map[string]any)
			if pane == nil {
				continue
			}
			if pid, _ := pane["id"].(string); pid == handle {
				return wsId, nil
			}
			if pref, _ := pane["ref"].(string); pref == handle {
				return wsId, nil
			}
		}
	}
	return "", fmt.Errorf("pane not found in any workspace")
}

func tmuxResolvePaneTarget(rc *rpcContext, raw string) (workspaceId string, paneId string, err error) {
	raw = strings.TrimSpace(raw)
	paneSelector := tmuxPaneSelector(raw)
	windowSelector := tmuxWindowSelector(raw)

	if windowSelector != "" {
		workspaceId, err = tmuxResolveWorkspaceTarget(rc, windowSelector)
		if err != nil {
			return "", "", err
		}
	} else if paneSelector != "" {
		workspaceId, err = tmuxWorkspaceIdForPaneHandle(rc, paneSelector)
		if err != nil {
			workspaceId, err = tmuxResolveWorkspaceTarget(rc, "")
			if err != nil {
				return "", "", err
			}
		}
	} else {
		workspaceId, err = tmuxResolveWorkspaceTarget(rc, "")
		if err != nil {
			return "", "", err
		}
	}

	if paneSelector != "" {
		paneId, err = tmuxCanonicalPaneId(rc, paneSelector, workspaceId)
		if err != nil {
			return "", "", err
		}
	} else if callerWs := tmuxResolvedCallerWorkspaceId(rc); callerWs == workspaceId {
		if callerPane := tmuxCallerPaneHandle(); callerPane != "" {
			if pid, err2 := tmuxCanonicalPaneId(rc, callerPane, workspaceId); err2 == nil {
				paneId = pid
			}
		}
	}

	if paneId == "" {
		paneId, err = tmuxFocusedPaneId(rc, workspaceId)
		if err != nil {
			return "", "", err
		}
	}
	return workspaceId, paneId, nil
}

func tmuxSelectedSurfaceId(rc *rpcContext, workspaceId string, paneId string) (string, error) {
	payload, err := rc.call("pane.surfaces", map[string]any{"workspace_id": workspaceId, "pane_id": paneId})
	if err != nil {
		return "", err
	}
	surfaces, _ := payload["surfaces"].([]any)
	for _, s := range surfaces {
		surface, _ := s.(map[string]any)
		if surface == nil {
			continue
		}
		if sel, _ := surface["selected"].(bool); sel {
			if id, _ := surface["id"].(string); id != "" {
				return id, nil
			}
		}
	}
	// Fall back to first surface
	if len(surfaces) > 0 {
		if surface, ok := surfaces[0].(map[string]any); ok {
			if id, _ := surface["id"].(string); id != "" {
				return id, nil
			}
		}
	}
	return "", fmt.Errorf("pane has no surface")
}

func tmuxResolveSurfaceTarget(rc *rpcContext, raw string) (workspaceId string, paneId string, surfaceId string, err error) {
	raw = strings.TrimSpace(raw)

	if tmuxPaneSelector(raw) != "" {
		workspaceId, paneId, err = tmuxResolvePaneTarget(rc, raw)
		if err != nil {
			return "", "", "", err
		}
		// When target pane matches caller's pane, prefer caller's surface
		callerPane := tmuxCallerPaneHandle()
		callerSurface := tmuxCallerSurfaceHandle()
		if callerPane != "" && callerSurface != "" {
			canonicalCallerPane, _ := tmuxCanonicalPaneId(rc, callerPane, workspaceId)
			if paneId == callerPane || paneId == canonicalCallerPane {
				surfaceId, err = tmuxCanonicalSurfaceId(rc, callerSurface, workspaceId)
				if err == nil {
					return
				}
			}
		}
		surfaceId, err = tmuxSelectedSurfaceId(rc, workspaceId, paneId)
		return
	}

	winSel := tmuxWindowSelector(raw)
	workspaceId, err = tmuxResolveWorkspaceTarget(rc, winSel)
	if err != nil {
		return "", "", "", err
	}

	// When no explicit target and caller workspace matches, use caller's surface
	if winSel == "" {
		if callerWs := tmuxResolvedCallerWorkspaceId(rc); callerWs == workspaceId {
			if callerSurface := tmuxCallerSurfaceHandle(); callerSurface != "" {
				surfaceId, err = tmuxCanonicalSurfaceId(rc, callerSurface, workspaceId)
				if err == nil {
					return
				}
			}
		}
	}

	// Fall back to focused surface
	payload, err := rc.call("surface.current", map[string]any{"workspace_id": workspaceId})
	if err == nil {
		if sid, ok := payload["surface_id"].(string); ok {
			surfaceId = sid
			return
		}
	}

	// Last resort: first surface in the workspace
	surfPayload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err == nil {
		surfs, _ := surfPayload["surfaces"].([]any)
		for _, s := range surfs {
			surf, _ := s.(map[string]any)
			if surf == nil {
				continue
			}
			if focused, _ := surf["focused"].(bool); focused {
				if id, _ := surf["id"].(string); id != "" {
					surfaceId = id
					return workspaceId, "", surfaceId, nil
				}
			}
		}
		if len(surfs) > 0 {
			if surf, ok := surfs[0].(map[string]any); ok {
				if id, _ := surf["id"].(string); id != "" {
					surfaceId = id
					return workspaceId, "", surfaceId, nil
				}
			}
		}
	}

	return "", "", "", fmt.Errorf("unable to resolve surface")
}

type tmuxSplitAnchor struct {
	targetSurfaceId string
	callerSurfaceId string
	direction       string
}

func tmuxAnchoredSplitTarget(rc *rpcContext, workspaceId string) *tmuxSplitAnchor {
	store := loadTmuxCompatStore()
	if mvState, ok := store.MainVerticalLayouts[workspaceId]; ok && mvState.LastColumnSurfaceId != "" {
		lastColumnId, err := tmuxCanonicalSurfaceId(rc, mvState.LastColumnSurfaceId, workspaceId)
		if err == nil {
			return &tmuxSplitAnchor{
				targetSurfaceId: lastColumnId,
				callerSurfaceId: "",
				direction:       "down",
			}
		}

		// Right-column anchors can outlive the pane they pointed at.
		// Drop stale state and rebuild from the caller surface instead.
		mvState.LastColumnSurfaceId = ""
		store.MainVerticalLayouts[workspaceId] = mvState
		delete(store.LastSplitSurface, workspaceId)
		_ = saveTmuxCompatStore(store)
	}

	candidateAnchors := []string{tmuxCallerSurfaceHandle()}
	if mvState, ok := store.MainVerticalLayouts[workspaceId]; ok && mvState.MainSurfaceId != "" {
		candidateAnchors = append(candidateAnchors, mvState.MainSurfaceId)
	}
	for _, candidate := range candidateAnchors {
		if candidate == "" {
			continue
		}
		anchorSurfaceId, err := tmuxCanonicalSurfaceId(rc, candidate, workspaceId)
		if err == nil {
			return &tmuxSplitAnchor{
				targetSurfaceId: anchorSurfaceId,
				callerSurfaceId: anchorSurfaceId,
				direction:       "right",
			}
		}
	}

	if _, ok := store.MainVerticalLayouts[workspaceId]; ok {
		delete(store.MainVerticalLayouts, workspaceId)
		delete(store.LastSplitSurface, workspaceId)
		_ = saveTmuxCompatStore(store)
	}
	return nil
}

// --- TmuxCompatStore (local JSON state) ---

type mainVerticalState struct {
	MainSurfaceId       string `json:"mainSurfaceId"`
	LastColumnSurfaceId string `json:"lastColumnSurfaceId,omitempty"`
}

type tmuxCompatStore struct {
	Buffers             map[string]string            `json:"buffers,omitempty"`
	Hooks               map[string]string            `json:"hooks,omitempty"`
	MainVerticalLayouts map[string]mainVerticalState `json:"mainVerticalLayouts,omitempty"`
	LastSplitSurface    map[string]string            `json:"lastSplitSurface,omitempty"`
}

func tmuxCompatStoreURL() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cmuxterm", "tmux-compat-store.json")
}

func loadTmuxCompatStore() tmuxCompatStore {
	data, err := os.ReadFile(tmuxCompatStoreURL())
	if err != nil {
		return tmuxCompatStore{
			Buffers:             make(map[string]string),
			Hooks:               make(map[string]string),
			MainVerticalLayouts: make(map[string]mainVerticalState),
			LastSplitSurface:    make(map[string]string),
		}
	}
	var store tmuxCompatStore
	if err := json.Unmarshal(data, &store); err != nil {
		return tmuxCompatStore{
			Buffers:             make(map[string]string),
			Hooks:               make(map[string]string),
			MainVerticalLayouts: make(map[string]mainVerticalState),
			LastSplitSurface:    make(map[string]string),
		}
	}
	if store.Buffers == nil {
		store.Buffers = make(map[string]string)
	}
	if store.Hooks == nil {
		store.Hooks = make(map[string]string)
	}
	if store.MainVerticalLayouts == nil {
		store.MainVerticalLayouts = make(map[string]mainVerticalState)
	}
	if store.LastSplitSurface == nil {
		store.LastSplitSurface = make(map[string]string)
	}
	return store
}

func saveTmuxCompatStore(store tmuxCompatStore) error {
	path := tmuxCompatStoreURL()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.Marshal(store)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func tmuxPruneCompatWorkspaceState(workspaceId string) error {
	store := loadTmuxCompatStore()
	changed := false
	if _, ok := store.MainVerticalLayouts[workspaceId]; ok {
		delete(store.MainVerticalLayouts, workspaceId)
		changed = true
	}
	if _, ok := store.LastSplitSurface[workspaceId]; ok {
		delete(store.LastSplitSurface, workspaceId)
		changed = true
	}
	if changed {
		return saveTmuxCompatStore(store)
	}
	return nil
}

func tmuxPruneCompatSurfaceState(workspaceId string, surfaceId string) error {
	store := loadTmuxCompatStore()
	changed := false
	if lastSplit := store.LastSplitSurface[workspaceId]; lastSplit == surfaceId {
		delete(store.LastSplitSurface, workspaceId)
		changed = true
	}
	if layout, ok := store.MainVerticalLayouts[workspaceId]; ok {
		if layout.MainSurfaceId == surfaceId {
			delete(store.MainVerticalLayouts, workspaceId)
			delete(store.LastSplitSurface, workspaceId)
			changed = true
		} else if layout.LastColumnSurfaceId == surfaceId {
			layout.LastColumnSurfaceId = ""
			store.MainVerticalLayouts[workspaceId] = layout
			changed = true
		}
	}
	if changed {
		return saveTmuxCompatStore(store)
	}
	return nil
}

// --- Special key translation ---

func tmuxSpecialKeyText(token string) string {
	switch strings.ToLower(token) {
	case "enter", "c-m", "kpenter":
		return "\r"
	case "tab", "c-i":
		return "\t"
	case "space":
		return " "
	case "bspace", "backspace":
		return "\x7f"
	case "escape", "esc", "c-[":
		return "\x1b"
	case "c-c":
		return "\x03"
	case "c-d":
		return "\x04"
	case "c-z":
		return "\x1a"
	case "c-l":
		return "\x0c"
	default:
		return ""
	}
}

func tmuxSendKeysText(tokens []string, literal bool) string {
	if literal {
		return strings.Join(tokens, " ")
	}
	var result strings.Builder
	pendingSpace := false
	for _, token := range tokens {
		if special := tmuxSpecialKeyText(token); special != "" {
			result.WriteString(special)
			pendingSpace = false
			continue
		}
		if pendingSpace {
			result.WriteByte(' ')
		}
		result.WriteString(token)
		pendingSpace = true
	}
	return result.String()
}

func tmuxShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func tmuxShellCommandText(positional []string, cwd string) string {
	cwd = strings.TrimSpace(cwd)
	cmd := strings.TrimSpace(strings.Join(positional, " "))
	if cwd == "" && cmd == "" {
		return ""
	}
	var pieces []string
	if cwd != "" {
		pieces = append(pieces, "cd -- "+tmuxShellQuote(cwd))
	}
	if cmd != "" {
		pieces = append(pieces, cmd)
	}
	return strings.Join(pieces, " && ") + "\r"
}

// --- Wait-for (filesystem-based signaling) ---

func tmuxWaitForSignalPath(name string) string {
	var sanitized strings.Builder
	for _, c := range name {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-' {
			sanitized.WriteRune(c)
		} else {
			sanitized.WriteByte('_')
		}
	}
	return fmt.Sprintf("/tmp/cmux-wait-for-%s.sig", sanitized.String())
}

// --- Main dispatch ---

func dispatchTmuxCommand(rc *rpcContext, command string, args []string) error {
	switch command {
	case "-v", "-V":
		fmt.Println("tmux 3.4")
		return nil

	case "new-session", "new":
		return tmuxNewSession(rc, args)
	case "new-window", "neww":
		return tmuxNewWindow(rc, args)
	case "split-window", "splitw":
		return tmuxSplitWindow(rc, args)
	case "select-window", "selectw":
		return tmuxSelectWindow(rc, args)
	case "select-pane", "selectp":
		return tmuxSelectPane(rc, args)
	case "kill-window", "killw":
		return tmuxKillWindow(rc, args)
	case "kill-pane", "killp":
		return tmuxKillPane(rc, args)
	case "send-keys", "send":
		return tmuxSendKeys(rc, args)
	case "capture-pane", "capturep":
		return tmuxCapturePane(rc, args)
	case "display-message", "display", "displayp":
		return tmuxDisplayMessage(rc, args)
	case "list-windows", "lsw":
		return tmuxListWindows(rc, args)
	case "list-panes", "lsp":
		return tmuxListPanes(rc, args)
	case "rename-window", "renamew":
		return tmuxRenameWindow(rc, args)
	case "resize-pane", "resizep":
		return tmuxResizePane(rc, args)
	case "wait-for":
		return tmuxWaitFor(rc, args)
	case "last-pane":
		return tmuxLastPane(rc, args)
	case "has-session", "has":
		return tmuxHasSession(rc, args)
	case "select-layout":
		return tmuxSelectLayout(rc, args)
	case "show-buffer", "showb":
		return tmuxShowBuffer(args)
	case "save-buffer", "saveb":
		return tmuxSaveBuffer(args)

	// No-ops
	case "set-option", "set", "set-window-option", "setw", "source-file",
		"refresh-client", "attach-session", "detach-client",
		"last-window", "next-window", "previous-window",
		"set-hook", "set-buffer", "list-buffers":
		return nil

	default:
		return fmt.Errorf("unsupported tmux command: %s", command)
	}
}

// --- Command implementations ---

func tmuxNewSession(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-n", "-s"}, []string{"-A", "-d", "-P"})
	if p.hasFlag("-A") {
		return fmt.Errorf("new-session -A is not supported")
	}
	params := map[string]any{"focus": false}
	if cwd := p.value("-c"); cwd != "" {
		params["cwd"] = cwd
	}
	created, err := rc.call("workspace.create", params)
	if err != nil {
		return err
	}
	wsId, _ := created["workspace_id"].(string)
	if wsId == "" {
		return fmt.Errorf("workspace.create did not return workspace_id")
	}
	if title := firstNonEmpty(p.value("-n"), p.value("-s")); strings.TrimSpace(title) != "" {
		rc.call("workspace.rename", map[string]any{"workspace_id": wsId, "title": title})
	}
	if text := tmuxShellCommandText(p.positional, p.value("-c")); text != "" {
		surfaceId, err := tmuxGetFirstSurface(rc, wsId)
		if err == nil {
			rc.call("surface.send_text", map[string]any{"workspace_id": wsId, "surface_id": surfaceId, "text": text})
		}
	}
	if p.hasFlag("-P") {
		ctx, err := tmuxFormatContext(rc, wsId, "", "")
		if err != nil {
			fmt.Printf("@%s\n", wsId)
			return nil
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, "@"+wsId))
	}
	return nil
}

func tmuxNewWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-n", "-t"}, []string{"-d", "-P"})
	params := map[string]any{"focus": false}
	if cwd := p.value("-c"); cwd != "" {
		params["cwd"] = cwd
	}
	created, err := rc.call("workspace.create", params)
	if err != nil {
		return err
	}
	wsId, _ := created["workspace_id"].(string)
	if wsId == "" {
		return fmt.Errorf("workspace.create did not return workspace_id")
	}
	if title := p.value("-n"); strings.TrimSpace(title) != "" {
		rc.call("workspace.rename", map[string]any{"workspace_id": wsId, "title": title})
	}
	if text := tmuxShellCommandText(p.positional, p.value("-c")); text != "" {
		surfaceId, err := tmuxGetFirstSurface(rc, wsId)
		if err == nil {
			rc.call("surface.send_text", map[string]any{"workspace_id": wsId, "surface_id": surfaceId, "text": text})
		}
	}
	if p.hasFlag("-P") {
		ctx, err := tmuxFormatContext(rc, wsId, "", "")
		if err != nil {
			fmt.Printf("@%s\n", wsId)
			return nil
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, "@"+wsId))
	}
	return nil
}

func tmuxSplitWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-l", "-t"}, []string{"-P", "-b", "-d", "-h", "-v"})

	targetWs, _, targetSurface, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}

	direction := "down"
	if p.hasFlag("-h") {
		direction = "right"
		if p.hasFlag("-b") {
			direction = "left"
		}
	} else if p.hasFlag("-b") {
		direction = "up"
	}

	// Anchor splits to the leader surface for agent teams.
	callerWorkspace := tmuxCallerWorkspaceHandle()
	anchoredCallerSurface := ""
	if callerWorkspace != "" {
		if wsId, err := tmuxResolveWorkspaceId(rc, callerWorkspace); err == nil {
			if anchored := tmuxAnchoredSplitTarget(rc, wsId); anchored != nil {
				targetWs = wsId
				targetSurface = anchored.targetSurfaceId
				direction = anchored.direction
				anchoredCallerSurface = anchored.callerSurfaceId
			}
		}
	}

	focusNewPane := !p.hasFlag("-d")
	created, err := rc.call("surface.split", map[string]any{
		"workspace_id": targetWs,
		"surface_id":   targetSurface,
		"direction":    direction,
		"focus":        focusNewPane,
	})
	if err != nil {
		return err
	}
	surfaceId, _ := created["surface_id"].(string)
	if surfaceId == "" {
		return fmt.Errorf("surface.split did not return surface_id")
	}
	newPaneId, _ := created["pane_id"].(string)

	// Track for main-vertical layout
	store := loadTmuxCompatStore()
	store.LastSplitSurface[targetWs] = surfaceId
	if _, ok := store.MainVerticalLayouts[targetWs]; ok {
		mvs := store.MainVerticalLayouts[targetWs]
		mvs.LastColumnSurfaceId = surfaceId
		store.MainVerticalLayouts[targetWs] = mvs
	} else if direction == "right" && anchoredCallerSurface != "" {
		store.MainVerticalLayouts[targetWs] = mainVerticalState{
			MainSurfaceId:       anchoredCallerSurface,
			LastColumnSurfaceId: surfaceId,
		}
	}
	saveTmuxCompatStore(store)

	// Equalize vertical splits
	rc.call("workspace.equalize_splits", map[string]any{
		"workspace_id": targetWs,
		"orientation":  "vertical",
	})

	if text := tmuxShellCommandText(p.positional, p.value("-c")); text != "" {
		rc.call("surface.send_text", map[string]any{
			"workspace_id": targetWs,
			"surface_id":   surfaceId,
			"text":         text,
		})
	}

	if p.hasFlag("-P") {
		ctx, err := tmuxFormatContext(rc, targetWs, newPaneId, surfaceId)
		if err != nil {
			fmt.Println(surfaceId)
			return nil
		}
		fallback := surfaceId
		if pid, ok := ctx["pane_id"]; ok {
			fallback = pid
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxSelectWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.select", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxSelectPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-P", "-T", "-t"}, nil)
	// -P (style) and -T (title) are no-ops
	if p.value("-P") != "" || p.value("-T") != "" {
		return nil
	}
	wsId, paneId, err := tmuxResolvePaneTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("pane.focus", map[string]any{"workspace_id": wsId, "pane_id": paneId})
	return err
}

func tmuxKillWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.close", map[string]any{"workspace_id": wsId})
	if err != nil {
		return err
	}
	_ = tmuxPruneCompatWorkspaceState(wsId)
	return nil
}

func tmuxKillPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("surface.close", map[string]any{"workspace_id": wsId, "surface_id": surfId})
	if err != nil {
		return err
	}
	_ = tmuxPruneCompatSurfaceState(wsId, surfId)
	// Re-equalize after removal
	rc.call("workspace.equalize_splits", map[string]any{"workspace_id": wsId, "orientation": "vertical"})
	return nil
}

func tmuxSendKeys(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, []string{"-l"})
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	text := tmuxSendKeysText(p.positional, p.hasFlag("-l"))
	if text != "" {
		_, err = rc.call("surface.send_text", map[string]any{
			"workspace_id": wsId,
			"surface_id":   surfId,
			"text":         text,
		})
	}
	return err
}

func tmuxCapturePane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-E", "-S", "-t"}, []string{"-J", "-N", "-p"})
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	params := map[string]any{
		"workspace_id": wsId,
		"surface_id":   surfId,
		"scrollback":   true,
	}
	if start := p.value("-S"); start != "" {
		if lines := parseInt(start); lines < 0 {
			params["lines"] = int(math.Abs(float64(lines)))
		}
	}
	payload, err := rc.call("surface.read_text", params)
	if err != nil {
		return err
	}
	text, _ := payload["text"].(string)
	if p.hasFlag("-p") {
		fmt.Print(text)
	} else {
		store := loadTmuxCompatStore()
		store.Buffers["default"] = text
		saveTmuxCompatStore(store)
	}
	return nil
}

func tmuxDisplayMessage(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, []string{"-p"})
	wsId, paneId, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	ctx, err := tmuxFormatContext(rc, wsId, paneId, surfId)
	if err != nil {
		ctx = map[string]string{}
	}

	// Enrich with geometry
	panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
	if err == nil {
		panes, _ := panePayload["panes"].([]any)
		containerFrame, _ := panePayload["container_frame"].(map[string]any)
		var matchingPane map[string]any
		if paneId != "" {
			for _, p := range panes {
				pn, _ := p.(map[string]any)
				if pid, _ := pn["id"].(string); pid == paneId {
					matchingPane = pn
					break
				}
			}
		}
		if matchingPane == nil {
			for _, p := range panes {
				pn, _ := p.(map[string]any)
				if focused, _ := pn["focused"].(bool); focused {
					matchingPane = pn
					break
				}
			}
		}
		if matchingPane == nil && len(panes) > 0 {
			matchingPane, _ = panes[0].(map[string]any)
		}
		if matchingPane != nil {
			tmuxEnrichContextWithGeometry(ctx, matchingPane, containerFrame)
		}
	}

	format := p.value("-F")
	if len(p.positional) > 0 {
		format = strings.Join(p.positional, " ")
	}
	rendered := tmuxRenderFormat(format, ctx, "")
	if p.hasFlag("-p") || rendered != "" {
		fmt.Println(rendered)
	}
	return nil
}

func tmuxListWindows(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, nil)
	items, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return err
	}
	for _, item := range items {
		wsId, _ := item["id"].(string)
		if wsId == "" {
			continue
		}
		ctx, err := tmuxFormatContext(rc, wsId, "", "")
		if err != nil {
			continue
		}
		fallback := ""
		if idx, ok := ctx["window_index"]; ok {
			fallback = idx
		} else {
			fallback = "?"
		}
		if name, ok := ctx["window_name"]; ok {
			fallback += " " + name
		} else {
			fallback += " " + wsId
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxListPanes(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, nil)

	target := p.value("-t")
	var wsId string
	var err error

	if target != "" && tmuxPaneSelector(target) != "" {
		wsId, _, err = tmuxResolvePaneTarget(rc, target)
	} else {
		wsId, err = tmuxResolveWorkspaceTarget(rc, target)
	}
	if err != nil {
		return err
	}

	payload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
	if err != nil {
		return err
	}
	panes, _ := payload["panes"].([]any)
	containerFrame, _ := payload["container_frame"].(map[string]any)

	for _, p2 := range panes {
		pane, _ := p2.(map[string]any)
		if pane == nil {
			continue
		}
		paneId, _ := pane["id"].(string)
		if paneId == "" {
			continue
		}
		ctx, err := tmuxFormatContext(rc, wsId, paneId, "")
		if err != nil {
			continue
		}
		tmuxEnrichContextWithGeometry(ctx, pane, containerFrame)
		fallback := "%" + paneId
		if pid, ok := ctx["pane_id"]; ok {
			fallback = pid
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxRenameWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	title := strings.TrimSpace(strings.Join(p.positional, " "))
	if title == "" {
		return fmt.Errorf("rename-window requires a title")
	}
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.rename", map[string]any{"workspace_id": wsId, "title": title})
	return err
}

func tmuxResizePane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t", "-x", "-y"}, []string{"-D", "-L", "-R", "-U"})
	wsId, paneId, err := tmuxResolvePaneTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}

	hasDirectional := p.hasFlag("-L") || p.hasFlag("-R") || p.hasFlag("-U") || p.hasFlag("-D")

	if !hasDirectional {
		if absWidthStr := p.value("-x"); absWidthStr != "" {
			absWidth := parseInt(strings.ReplaceAll(absWidthStr, "%", ""))
			// Get current width to compute delta
			panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
			if err != nil {
				return err
			}
			panes, _ := panePayload["panes"].([]any)
			for _, pp := range panes {
				pane, _ := pp.(map[string]any)
				if pane == nil {
					continue
				}
				if pid, _ := pane["id"].(string); pid == paneId {
					cellW := intFromAnyGo(pane["cell_width_px"])
					currentCols := intFromAnyGo(pane["columns"])
					if cellW > 0 && currentCols >= 0 {
						delta := absWidth - currentCols
						if delta != 0 {
							dir := "right"
							if delta < 0 {
								dir = "left"
								delta = -delta
							}
							rc.call("pane.resize", map[string]any{
								"workspace_id": wsId,
								"pane_id":      paneId,
								"direction":    dir,
								"amount":       delta * cellW,
							})
						}
					}
					break
				}
			}
			return nil
		}
	}

	if hasDirectional {
		dir := "right"
		if p.hasFlag("-L") {
			dir = "left"
		} else if p.hasFlag("-U") {
			dir = "up"
		} else if p.hasFlag("-D") {
			dir = "down"
		}
		rawAmount := firstNonEmpty(p.value("-x"), p.value("-y"), "5")
		rawAmount = strings.ReplaceAll(rawAmount, "%", "")
		amount := parseInt(rawAmount)
		if amount <= 0 {
			amount = 5
		}
		_, err := rc.call("pane.resize", map[string]any{
			"workspace_id": wsId,
			"pane_id":      paneId,
			"direction":    dir,
			"amount":       amount,
		})
		return err
	}
	return nil
}

func tmuxWaitFor(_ *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"--timeout"}, []string{"-S"})
	name := ""
	for _, pos := range p.positional {
		if !strings.HasPrefix(pos, "-") {
			name = pos
			break
		}
	}
	if name == "" {
		return fmt.Errorf("wait-for requires a name")
	}

	signalPath := tmuxWaitForSignalPath(name)

	if p.hasFlag("-S") {
		// Signal mode: create the file
		os.WriteFile(signalPath, []byte{}, 0644)
		fmt.Println("OK")
		return nil
	}

	// Wait mode: poll for the file
	timeoutStr := p.value("--timeout")
	timeout := 30.0
	if timeoutStr != "" {
		if t := parseFloat(timeoutStr); t > 0 {
			timeout = t
		}
	}

	deadline := time.Now().Add(time.Duration(timeout * float64(time.Second)))
	for time.Now().Before(deadline) {
		if _, err := os.Stat(signalPath); err == nil {
			os.Remove(signalPath)
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("wait-for timeout: %s", name)
}

func tmuxLastPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("pane.last", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxHasSession(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	_, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	return err
}

func tmuxSelectLayout(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	layoutName := ""
	if len(p.positional) > 0 {
		layoutName = p.positional[0]
	}

	// Resolve workspace from target (may be a pane reference)
	var wsId string
	var err error
	if target := p.value("-t"); target != "" {
		if tmuxPaneSelector(target) != "" {
			wsId, _, err = tmuxResolvePaneTarget(rc, target)
		} else {
			wsId, err = tmuxResolveWorkspaceTarget(rc, target)
		}
	} else {
		wsId, err = tmuxResolveWorkspaceTarget(rc, "")
	}
	if err != nil {
		return err
	}

	if layoutName == "main-vertical" || layoutName == "main-horizontal" {
		orientation := "vertical"
		if layoutName == "main-horizontal" {
			orientation = "horizontal"
		}
		rc.call("workspace.equalize_splits", map[string]any{
			"workspace_id": wsId,
			"orientation":  orientation,
		})
	} else {
		rc.call("workspace.equalize_splits", map[string]any{"workspace_id": wsId})
	}

	if layoutName == "main-vertical" {
		if callerSurface := tmuxCallerSurfaceHandle(); callerSurface != "" {
			store := loadTmuxCompatStore()
			existingColumn := ""
			if existing, ok := store.MainVerticalLayouts[wsId]; ok {
				existingColumn = existing.LastColumnSurfaceId
			}
			seedColumn := existingColumn
			if seedColumn == "" {
				seedColumn = store.LastSplitSurface[wsId]
			}
			store.MainVerticalLayouts[wsId] = mainVerticalState{
				MainSurfaceId:       callerSurface,
				LastColumnSurfaceId: seedColumn,
			}
			saveTmuxCompatStore(store)
		}
	} else if layoutName != "" {
		_ = tmuxPruneCompatWorkspaceState(wsId)
	}

	return nil
}

func tmuxShowBuffer(args []string) error {
	p := parseTmuxArgs(args, []string{"-b"}, nil)
	name := p.value("-b")
	if name == "" {
		name = "default"
	}
	store := loadTmuxCompatStore()
	if buf, ok := store.Buffers[name]; ok {
		fmt.Print(buf)
	}
	return nil
}

func tmuxSaveBuffer(args []string) error {
	p := parseTmuxArgs(args, []string{"-b"}, nil)
	name := p.value("-b")
	if name == "" {
		name = "default"
	}
	store := loadTmuxCompatStore()
	buf, ok := store.Buffers[name]
	if !ok {
		return fmt.Errorf("buffer not found: %s", name)
	}
	if len(p.positional) > 0 {
		outputPath := strings.TrimSpace(p.positional[len(p.positional)-1])
		if outputPath != "" {
			return os.WriteFile(outputPath, []byte(buf), 0644)
		}
	}
	fmt.Print(buf)
	return nil
}

// --- Helpers ---

func tmuxGetFirstSurface(rc *rpcContext, workspaceId string) (string, error) {
	payload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return "", err
	}
	surfaces, _ := payload["surfaces"].([]any)
	if len(surfaces) == 0 {
		return "", fmt.Errorf("workspace has no surfaces")
	}
	// Prefer focused surface
	for _, s := range surfaces {
		surf, _ := s.(map[string]any)
		if focused, _ := surf["focused"].(bool); focused {
			if id, _ := surf["id"].(string); id != "" {
				return id, nil
			}
		}
	}
	if surf, ok := surfaces[0].(map[string]any); ok {
		if id, _ := surf["id"].(string); id != "" {
			return id, nil
		}
	}
	return "", fmt.Errorf("workspace has no surfaces")
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func parseInt(s string) int {
	s = strings.TrimSpace(s)
	var n int
	fmt.Sscanf(s, "%d", &n)
	return n
}

func parseFloat(s string) float64 {
	s = strings.TrimSpace(s)
	var f float64
	fmt.Sscanf(s, "%f", &f)
	return f
}
