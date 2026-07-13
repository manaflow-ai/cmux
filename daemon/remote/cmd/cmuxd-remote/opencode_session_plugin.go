package main

import (
	"fmt"
	"os"
	"path/filepath"
)

const remoteOpenCodeSessionPluginSource = `// cmux-opencode-session-plugin-marker remote-v1
// Bridges remote OpenCode lifecycle events into the host cmux feed.
// Installed by cmux omo-slim. DO NOT EDIT MANUALLY.

import { spawnSync } from "node:child_process";

const CMUX_PLUGIN_INSTALLED_KEY = Symbol.for("cmux.remote.session.plugin.installed");

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return null;
}

function propertiesFor(event) {
  return (event && typeof event === "object" && event.properties) || {};
}

function sessionIdFor(event) {
  const properties = propertiesFor(event);
  return firstString(
    properties.info && properties.info.id,
    properties.sessionID,
    properties.sessionId,
    properties.session_id,
    properties.session && properties.session.id,
    event && event.sessionID,
    event && event.sessionId,
    event && event.id
  );
}

function cwdFor(ctx, event) {
  const properties = propertiesFor(event);
  return firstString(
    properties.info && properties.info.directory,
    properties.cwd,
    properties.directory,
    ctx && ctx.directory,
    process.cwd()
  );
}

function sendLifecycle(hookEventName, ctx, event) {
  const sessionId = sessionIdFor(event);
  if (!sessionId || !process.env.CMUX_SURFACE_ID) return;

  const feedEvent = {
    session_id: sessionId,
    hook_event_name: hookEventName,
    _source: "opencode",
    cwd: cwdFor(ctx, event),
    workspace_id: process.env.CMUX_WORKSPACE_ID,
    surface_id: process.env.CMUX_SURFACE_ID,
    _opencode_request_id: "remote-" + sessionId + "-" + hookEventName + "-" + Date.now(),
  };
  const cmux = process.env.CMUX_OMO_SLIM_CMUX_BIN || "cmux";
  try {
    spawnSync(cmux, ["rpc", "feed.push", JSON.stringify({
      event: feedEvent,
      wait_timeout_seconds: 0,
    })], {
      encoding: "utf8",
      env: process.env,
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 5000,
    });
  } catch (_) {}
}

const CMUXRemoteSessionBridge = async (ctx) => {
  if (globalThis[CMUX_PLUGIN_INSTALLED_KEY]) return {};
  globalThis[CMUX_PLUGIN_INSTALLED_KEY] = true;
  return {
    event: async ({ event }) => {
      const properties = propertiesFor(event);
      switch (event && event.type) {
        case "session.created":
          sendLifecycle("SessionStart", ctx, event);
          break;
        case "session.updated":
          sendLifecycle(
            properties.info && properties.info.time && properties.info.time.archived
              ? "SessionEnd"
              : "SessionStart",
            ctx,
            event
          );
          break;
        case "session.status":
          if (properties.status && properties.status.type === "idle") {
            sendLifecycle("Stop", ctx, event);
          }
          break;
        case "session.idle":
          sendLifecycle("Stop", ctx, event);
          break;
        case "session.deleted":
          sendLifecycle("SessionEnd", ctx, event);
          break;
        default:
          break;
      }
    },
  };
};

export { CMUXRemoteSessionBridge };
export default CMUXRemoteSessionBridge;
`

func writeRemoteOpenCodeSessionPlugin(shadowDir string) error {
	pluginDir := filepath.Join(shadowDir, "plugins")
	if err := os.MkdirAll(pluginDir, 0755); err != nil {
		return fmt.Errorf("create remote session plugin dir: %w", err)
	}

	pluginPath := filepath.Join(pluginDir, "cmux-session.js")
	if existing, err := os.ReadFile(pluginPath); err == nil && string(existing) == remoteOpenCodeSessionPluginSource {
		return nil
	}

	tempFile, err := os.CreateTemp(pluginDir, ".cmux-session.js.tmp-*")
	if err != nil {
		return fmt.Errorf("create remote session plugin temp file: %w", err)
	}
	tempPath := tempFile.Name()
	defer os.Remove(tempPath)

	if _, err := tempFile.WriteString(remoteOpenCodeSessionPluginSource); err != nil {
		tempFile.Close()
		return fmt.Errorf("write remote session plugin: %w", err)
	}
	if err := tempFile.Chmod(0644); err != nil {
		tempFile.Close()
		return fmt.Errorf("chmod remote session plugin: %w", err)
	}
	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close remote session plugin: %w", err)
	}
	if err := os.Rename(tempPath, pluginPath); err != nil {
		return fmt.Errorf("replace remote session plugin: %w", err)
	}
	return nil
}
