// l10n-allow-file: test fixtures (tool names, commands and paths), not shipped UI.
// Tool rows and the live line worded and laid out as Claude Code desktop draws them (Leo,
// 2026-11-03: "i feel like comparing claude code's to ours, we're not faithfully following how
// they're doing stuff" / "wrt tool calls and the lowest level thinking"). A finished call is one
// muted line, verb then tool ("Used repo: repo grep", "Ran git status", "Read App.tsx"); the live
// line is one line naming the current action ("Using repo: repo grep"), its verb in full ink and the
// rest muted, then the turn's time and its tokens as one count ("3m 2s · 47.4K tokens"). The
// shimmer stays the line's only working mark ("we don't want the claude symbol ellipsis thing btw
// we just keep the shimmer ONLY").
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { mcpCall, mcpLabel } from "../src/agent-session/acpmux/conversation/mcpCalls";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { WorkingCountsContext, type WorkingCounts } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { toolLabel } from "../src/agent-session/acpmux/toolPaths";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const t = translatorFor("en");
const ran = (command: string) => t("tools.ranCommand", { command });

const grep = (status: Tool["status"]): Tool => ({
  id: "grep-1",
  title: "mcp__repo__repo_grep",
  kind: "other",
  status,
});

test("a finished MCP call reads Used <server>: <tool>", () => {
  expect(toolLabel(grep("completed"), "", ran)).toBe("Used repo: repo grep");
  expect(mcpLabel(t, [mcpCall(grep("completed"))!], new Map())).toBe("Used repo: repo grep");
});

test("a running MCP call reads Using <server>: <tool>", () => {
  expect(toolLabel(grep("in_progress"), "", ran)).toBe("Using repo: repo grep");
  expect(mcpLabel(t, [mcpCall(grep("in_progress"))!], new Map(), true)).toBe("Using repo: repo grep");
});

test("a finished command and a read read verb then subject", () => {
  const command: Tool = { id: "c1", title: "git status", kind: "execute", status: "completed", command: "git status" };
  expect(toolLabel(command, "", ran)).toBe("Ran git status");
  const read: Tool = {
    id: "r1",
    title: "Read App.tsx",
    kind: "read",
    status: "completed",
    locations: [{ path: "/work/app/src/App.tsx" }],
  };
  expect(toolLabel(read, "", ran, "/work/app/src")).toBe("Read App.tsx");
});

test("the live line names the MCP call in flight the way Claude Code does", () => {
  const user: AcpmuxRow = { id: "u1", version: 1, at: 0, kind: "user", text: "find it" };
  const activity: AcpmuxRow = {
    id: "a1",
    version: 1,
    at: 1,
    kind: "activity",
    // Two calls to one tool share a closed line, so the live line is what names the running one.
    items: [
      { kind: "tool", text: "mcp__repo__repo_grep", tool: grep("completed") },
      { kind: "tool", text: "mcp__repo__repo_grep", tool: { ...grep("in_progress"), id: "grep-2" } },
    ],
  };
  const live = turnView([user, activity], new Set(), { working: true }).find((row) => row.kind === WORKING);
  expect(live?.doing).toBe("Using repo: repo grep");
});

const START = Date.UTC(2026, 10, 3, 6, 0, 0);
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 47_400,
  split: { output: 47_400, input: 9_000, cacheRead: 2_650_000, cacheWrite: 41_000 },
};
const liveLine = (props: Parameters<typeof Thinking>[0]) =>
  renderToStaticMarkup(
    <WorkingCountsContext.Provider value={counts}>
      <Thinking since={START} now={() => START + 182_000} {...props} />
    </WorkingCountsContext.Provider>,
  );
/// What a reader sees: the base words, the time and the counts, never the shimmer's lit copy.
const shown = (html: string) =>
  html
    .replace(/<span class="cv-shimmer__band"[\s\S]*?<\/span><\/span>/g, "")
    .replace(/<span class="cv-worked__lead">([^<]*)<\/span>/g, "$1")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

afterEach(() => {
  delete globalThis.cmuxExperiments;
});

test("the live line is one line: the action, its time, then the turn's tokens as one count", () => {
  const html = liveLine({ doing: "Using repo: repo grep" });
  expect(html.match(/class="cv-worked( |")/g)).toHaveLength(1);
  expect(shown(html)).toBe("Using repo: repo grep 3m 2s · 47.4K tokens");
  // The split stays on hover, named part by part.
  expect(html).toContain('title="Output 47.4K · fresh input 9K · cache reads 2.7M · cache writes 41K"');
  expect(html).not.toContain("↑");
});

test("the live line's action is in full ink and the rest of its words muted", () => {
  expect(liveLine({ doing: "Using repo: repo grep" })).toContain(
    '<span class="cv-shimmer__base"><span class="cv-worked__lead">Using repo</span>: repo grep</span>',
  );
  expect(liveLine({ doing: "git status", doingShell: true })).toContain(
    '<span class="cv-shimmer__base"><span class="cv-worked__lead">Running</span> git status</span>',
  );
  expect(liveLine({ sendTo: "coord", doing: "acpmux send coord hi", doingShell: true })).toContain(
    '<span class="cv-shimmer__base"><span class="cv-worked__lead">Sending</span> message to coord</span>',
  );
});

test("the live line draws no mark of its own: the shimmer is its only working sign", () => {
  const html = liveLine({ doing: "Using repo: repo grep" });
  expect(html).toContain("cv-shimmer__band");
  expect(html).not.toContain("cv-spinner");
  expect(html).not.toContain("cv-tool__icon");
});

test("the split arm keeps out and in on the live line", () => {
  globalThis.cmuxExperiments = { "live-line-tokens": "split" };
  expect(shown(liveLine({ doing: "Using repo: repo grep" }))).toBe(
    "Using repo: repo grep 3m 2s · ↓ 47.4K out ↑ 2.7M in",
  );
});
