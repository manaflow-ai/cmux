package main

import (
	"errors"
	"os"
	"strings"
	"time"
)

const agentLaunchContextTimeout = 5 * time.Second

var errAgentLaunchContextRequired = errors.New("launch requires a live cmux surface context")

type agentLaunchContext struct {
	workspaceId string
	windowId    string
	paneHandle  string
	paneId      string
	surfaceId   string
}

func agentLaunchContextForInvocation(rc *rpcContext, nonLaunch bool) (*agentLaunchContext, error) {
	context := inheritedAgentLaunchContext(rc)
	if context == nil && !nonLaunch {
		return nil, errAgentLaunchContextRequired
	}
	return context, nil
}

func inheritedAgentLaunchContext(rc *rpcContext) *agentLaunchContext {
	return inheritedAgentLaunchContextWithTimeout(rc, agentLaunchContextTimeout)
}

func inheritedAgentLaunchContextWithTimeout(rc *rpcContext, timeout time.Duration) *agentLaunchContext {
	workspaceHandle := strings.TrimSpace(os.Getenv("CMUX_WORKSPACE_ID"))
	surfaceHandle := strings.TrimSpace(os.Getenv("CMUX_SURFACE_ID"))
	if workspaceHandle == "" || surfaceHandle == "" {
		return nil
	}

	result := make(chan *agentLaunchContext, 1)
	go func() {
		result <- resolveInheritedAgentLaunchContext(rc, workspaceHandle, surfaceHandle)
	}()

	if timeout <= 0 {
		return <-result
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case context := <-result:
		return context
	case <-timer.C:
		return nil
	}
}

func resolveInheritedAgentLaunchContext(
	rc *rpcContext,
	workspaceHandle string,
	surfaceHandle string,
) *agentLaunchContext {
	if context := agentLaunchContextForSurface(rc, workspaceHandle, surfaceHandle); context != nil {
		return context
	}

	// A surface UUID survives moves between workspaces. Relocate only that exact
	// inherited surface from structured state; never substitute global focus.
	surfaceId := tmuxTrimIdSigil(surfaceHandle)
	if !isUUIDish(surfaceId) {
		return nil
	}
	payload, err := rc.call("surface.list", map[string]any{"surface_id": surfaceId})
	if err != nil {
		return nil
	}
	workspaceId := stringFromAnyGo(payload["workspace_id"])
	if !isUUIDish(workspaceId) {
		return nil
	}
	return agentLaunchContextFromSurfacePayload(rc, payload, workspaceId, surfaceId, surfaceId)
}

func agentLaunchContextForSurface(
	rc *rpcContext,
	workspaceHandle string,
	surfaceHandle string,
) *agentLaunchContext {
	workspaceId, err := tmuxResolveWorkspaceId(rc, workspaceHandle)
	if err != nil {
		return nil
	}
	surfaceId, err := tmuxCanonicalSurfaceId(rc, surfaceHandle, workspaceId)
	if err != nil {
		return nil
	}
	payload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return nil
	}
	return agentLaunchContextFromSurfacePayload(rc, payload, workspaceId, surfaceId, surfaceHandle)
}

func agentLaunchContextFromSurfacePayload(
	rc *rpcContext,
	payload map[string]any,
	workspaceId string,
	surfaceId string,
	surfaceHandle string,
) *agentLaunchContext {
	surfaces, _ := payload["surfaces"].([]any)
	normalizedSurfaceHandle := tmuxTrimIdSigil(surfaceHandle)
	var matched map[string]any
	for _, rawSurface := range surfaces {
		surface, _ := rawSurface.(map[string]any)
		if surface == nil {
			continue
		}
		if stringFromAnyGo(surface["id"]) == surfaceId ||
			stringFromAnyGo(surface["ref"]) == normalizedSurfaceHandle {
			matched = surface
			break
		}
	}
	if matched == nil {
		return nil
	}
	paneHandle := stringFromAnyGo(matched["pane_id"])
	if paneHandle == "" {
		paneHandle = stringFromAnyGo(matched["pane_ref"])
	}
	if paneHandle == "" {
		return nil
	}
	paneId, _ := tmuxCanonicalPaneId(rc, paneHandle, workspaceId)
	return &agentLaunchContext{
		workspaceId: workspaceId,
		windowId:    firstNonEmptyString(payload["window_id"], payload["window_ref"]),
		paneHandle:  paneHandle,
		paneId:      paneId,
		surfaceId:   surfaceId,
	}
}

func firstNonEmptyString(values ...any) string {
	for _, value := range values {
		if result := stringFromAnyGo(value); result != "" {
			return result
		}
	}
	return ""
}
