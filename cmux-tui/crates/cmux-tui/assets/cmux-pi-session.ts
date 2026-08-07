// cmux-tui-pi-session-extension v1
// Reports Pi lifecycle to the remote cmux-tui session that owns this terminal.

import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

function report(ctx: ExtensionContext, state: "working" | "idle" | "done"): void {
  const socket = process.env.CMUX_TUI_SOCKET;
  const terminal = process.env.CMUX_TUI_TERMINAL_ID;
  const session = ctx.sessionManager.getSessionId();
  if (!socket || !terminal || !session) return;

  const binary = process.env.CMUX_TUI_BIN || "cmux-tui";
  const child = spawn(binary, [
    "--socket", socket,
    "--quiet",
    "agent", "report",
    "--terminal", terminal,
    "--state", state,
    "--source", "hook",
    "--source-session", session,
  ], {
    shell: false,
    stdio: "ignore",
  });
  child.on("error", () => {});
  child.unref();
}

export default function cmuxTuiPiSession(pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => report(ctx, "idle"));
  pi.on("before_agent_start", (_event, ctx) => report(ctx, "working"));
  pi.on("agent_settled", (_event, ctx) => report(ctx, "done"));
  pi.on("session_shutdown", (_event, ctx) => report(ctx, "done"));
}
