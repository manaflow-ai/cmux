// l10n-allow-file: assertions use the localized builder output, not shipped copy.
// `/mcp` in a GUI agent chat (user, 2026-11-06: "/mcp doesn't work in cmux agent GUIs"). Before, the
// composer did not own it: it went to the harness as a prompt, where Claude Code over ACP answers
// "isn't available in this environment" and Codex's app-server reads it as text. Now it is cmux's,
// in every harness, and shows (or changes) the chat's MCP servers.
import { expect, test } from "bun:test";
import {
  cmuxCommandRefusal,
  composerCommand,
  harnessTakesToo,
  mcpCommandPlan,
  mergedCommands,
} from "../src/agent-session/acpmux/cmuxCommands";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import { connectorServers } from "../src/agent-session/acpmux/session-info/connectorServers";
import { connectorsSection } from "../src/agent-session/acpmux/session-info/native/connectors";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import type { ChatTool } from "../src/agent-session/acpmux/summary/chatTools";

const t: Translate = (key, values) => translate(key, values, "en");
const state = {
  summary: true,
  forkable: true,
  sideAvailable: true,
  canContinue: true,
  sideSessions: true,
  session: true,
  isSideSession: false,
  targets: [],
};
const tool = (name: string, extra: Partial<ChatTool> = {}): ChatTool => ({
  id: `mcp:${name}`,
  name,
  kind: "mcp",
  source: "claude",
  enabled: true,
  canToggle: true,
  ...extra,
});

test("/mcp is cmux's in Claude and Codex chats, never sent to the harness as a prompt", () => {
  for (const harness of ["claude", "claude-sr", "codex", "opencode"]) {
    for (const text of ["/mcp", "/mcp reconnect github", "/MCP"]) {
      const command = composerCommand(text.toLowerCase(), harness);
      expect(command?.kind).toBe("cmux");
      if (command?.kind !== "cmux") throw new Error(text);
      expect(command.command.action).toBe("mcp");
      expect(harnessTakesToo(command.command)).toBe(false);
    }
  }
  // The slash menu offers it, and a harness's own /mcp (Claude Code may list one) gives way to it.
  const menu = mergedCommands([{ name: "mcp", description: "Claude Code's", source: "agent" }]);
  expect(menu.filter((command) => command.name === "mcp").map((command) => command.source)).toEqual(["cmux"]);
});

test("/mcp needs a chat: New Tab and a chat not started yet say why", () => {
  const command = composerCommand("/mcp", "claude");
  if (command?.kind !== "cmux") throw new Error("/mcp");
  expect(cmuxCommandRefusal(command.command, "", { ...state, newTab: true })).toBe("composer.cmuxMcpUnavailable");
  expect(cmuxCommandRefusal(command.command, "", { ...state, session: false })).toBe("composer.cmuxMcpUnavailable");
  expect(cmuxCommandRefusal(command.command, "", state)).toBeUndefined();
});

test("/mcp subcommands reconnect, enable and disable a server the chat has", () => {
  const claude = {
    servers: [
      { name: "github", status: "failed" as const },
      { name: "linear", status: "connected" as const },
    ],
    tools: [tool("github"), tool("linear"), tool("pinned", { canToggle: false })],
    reconnects: true,
  };
  expect(mcpCommandPlan("", claude)).toEqual({ kind: "show" });
  expect(mcpCommandPlan(undefined, claude)).toEqual({ kind: "show" });
  expect(mcpCommandPlan("reconnect GitHub", claude)).toEqual({ kind: "reconnect", server: "github" });
  expect(mcpCommandPlan("disable linear", claude)).toEqual({
    kind: "set",
    id: "mcp:linear",
    server: "linear",
    enabled: false,
  });
  expect(mcpCommandPlan("enable linear", claude)).toMatchObject({ kind: "set", enabled: true });
  expect(mcpCommandPlan("disable pinned", claude)).toEqual({ kind: "refuse", key: "summary.tools.fixed" });
  expect(mcpCommandPlan("disable nope", claude)).toEqual({
    kind: "refuse",
    key: "composer.cmuxMcpUnknown",
    values: { server: "nope" },
  });
  expect(mcpCommandPlan("list", claude)).toEqual({ kind: "refuse", key: "composer.cmuxMcpUsage" });
  expect(mcpCommandPlan("reconnect", claude)).toEqual({ kind: "refuse", key: "composer.cmuxMcpUsage" });
  // A Codex chat: no reconnect, and its servers are fixed at start.
  const codex = {
    servers: [{ name: "cmux", status: "on" as const }],
    reconnects: false,
    toolsRefusal: "summary.tools.immutable" as const,
  };
  expect(mcpCommandPlan("reconnect cmux", codex)).toEqual({ kind: "refuse", key: "composer.cmuxMcpNoReconnect" });
  expect(mcpCommandPlan("disable cmux", codex)).toEqual({ kind: "refuse", key: "summary.tools.immutable" });
  // A browser over the web relay cannot change a chat's tools, and says so.
  expect(mcpCommandPlan("disable linear", { ...claude, toolsRefusal: "summary.tools.remote" })).toEqual({
    kind: "refuse",
    key: "summary.tools.remote",
  });
});

test("Connectors lists a Codex chat's servers as on or off, and a Claude chat's turned-off ones", () => {
  // Codex reports no server state: acpmux's tool rows are what the chat started with.
  const codex = connectorServers({
    tools: [
      tool("cmux", { kind: "cmux", source: "cmux" }),
      tool("forum", { enabled: false }),
      { ...tool("x"), id: "skill:x", kind: "skill" },
    ],
  });
  expect(codex).toEqual([
    { name: "cmux", status: "on" },
    { name: "forum", status: "off" },
  ]);
  const section = connectorsSection({ servers: codex, open: true }, new NativeInfoActions(), t)!;
  expect(section.rows.map((row) => [row.title, row.trailing])).toEqual([
    ["cmux", t("sessionInfo.connectors.on")],
    ["forum", t("sessionInfo.connectors.off")],
  ]);
  // Nobody said Codex's servers connected: the summary is only how many are on.
  expect(section.meta).toBe("1");
  // Claude reports its loaded servers; one the chat turned off is still listed, as off.
  expect(
    connectorServers({
      mcpServers: [{ name: "github", status: "connected" }],
      tools: [tool("github"), tool("linear", { enabled: false }), tool("unreported")],
    }),
  ).toEqual([
    { name: "github", status: "connected" },
    { name: "linear", status: "off" },
  ]);
  expect(connectorServers(undefined)).toEqual([]);
});
