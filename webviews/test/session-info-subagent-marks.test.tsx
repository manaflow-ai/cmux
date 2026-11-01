// Leo, 2026-10-29, on Session Info's Subagents: "the fact that there's all of these icons that are
// literally all the same icon, that's terrible. You can, like surely you can just at least say, you
// know, one of these is Codex, one of these is Claude, or something ... If you don't have anything
// else, you can just randomize the colors or something." Each line draws its harness's mark (the
// picker's own AgentMark): another family's agent its harness, the chat's own subagents the chat's,
// a started chat its own. A line with no mark keeps the icon in a stable tone of its own id
// (agentTones.ts), so the same agent is the same color on every render. The icon is AgentMark's
// fallback, so a harness acpmux has no drawable icon for (a glyph) still shows it.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ChildSessionRows } from "../src/agent-session/acpmux/session-info/ChildSessionRows";
import { SubagentsSection } from "../src/agent-session/acpmux/session-info/SubagentsSection";
import type { StartedSession } from "../src/agent-session/acpmux/started/startedSessions";
import { rowIconSize } from "../src/agent-session/acpmux/icons/iconSize";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { AgentMark } from "../src/agent-session/shared/AgentMark";
import { rememberHarnessIcons } from "../src/agent-session/shared/harnessIcons";

const agent = (id: string, harness?: string): Subagent => ({
  id,
  parent: null,
  name: id,
  kind: "Explore",
  task: id,
  state: "running",
  startedAt: 1,
  ...(harness ? { harness } : {}),
});

const session = (sessionId: string, harness?: string): StartedSession => ({
  sessionId,
  title: sessionId,
  state: "running",
  ...(harness ? { harness } : {}),
});

/// Each icon span's inner markup, and the tone of the icon it falls back to, in order.
const icons = (html: string) =>
  [...html.matchAll(/<span class="acpmux-lineage__icon[^"]*"[^>]*>(.*?)<\/span><span class="acpmux-summary-text/g)].map(
    (match) => ({ inner: match[1]!, tone: /class="acpmux-toned-icon" data-agent-tone="(\d)"/.exec(match[1]!)?.[1] }),
  );

const mark = (harness: string) => renderToStaticMarkup(<AgentMark agent={harness} size={rowIconSize(12)} />);

test("a subagent line draws its harness's mark: another family's its own, the chat's own the chat's", () => {
  const html = renderToStaticMarkup(
    <SubagentsSection agents={[agent("reviewer", "codex"), agent("explorer")]} waiting={new Set()} harness="claude" />,
  );
  const [codex, claude] = icons(html);
  expect(codex?.inner).toBe(mark("codex"));
  expect(claude?.inner).toBe(mark("claude"));
  expect(codex?.tone).toBeUndefined();
  expect(mark("codex")).not.toBe(mark("claude"));
});

test("with no harness to show, each line keeps its icon in its own stable tone", () => {
  const ids = ["aiforui-course", "opt-memory", "ui-think-tank", "fleet-mesh", "grid-system"];
  const html = renderToStaticMarkup(<SubagentsSection agents={ids.map((id) => agent(id))} waiting={new Set()} />);
  const tones = icons(html).map((icon) => icon.tone);
  expect(tones).toEqual(ids.map((id) => String(agentTone(id))));
  expect(new Set(tones).size).toBeGreaterThan(1);
  // A second render draws the same icon in the same tone for each line. Only the icons are compared:
  // the lines' elapsed time can tick between the two renders.
  const again = renderToStaticMarkup(<SubagentsSection agents={ids.map((id) => agent(id))} waiting={new Set()} />);
  expect(icons(again)).toEqual(icons(html));
});

test("a chat the agent started draws its own harness's mark, else its icon in its own tone", () => {
  const html = renderToStaticMarkup(
    <SubagentsSection
      agents={[]}
      waiting={new Set()}
      sessions={[session("codex-child", "codex"), session("plain-child")]}
    />,
  );
  const [codex, plain] = icons(html);
  expect(codex?.inner).toBe(mark("codex"));
  expect(plain?.tone).toBe(String(agentTone("plain-child")));

  const rows = renderToStaticMarkup(
    <ChildSessionRows sessions={[session("codex-child", "codex"), session("plain-child")]} />,
  );
  expect(rows).toContain(mark("codex"));
  expect(rows).toContain(`data-agent-tone="${agentTone("plain-child")}"`);
});

test("a harness with no drawable mark (a glyph icon) keeps the toned icon, and takes its icon once acpmux sends one", () => {
  rememberHarnessIcons([{ id: "glyph-harness", iconSpec: { kind: "glyph", name: "terminal", source: "default" } }]);
  const render = () =>
    renderToStaticMarkup(
      <SubagentsSection
        agents={[agent("helper", "glyph-harness")]}
        waiting={new Set()}
        sessions={[session("late-child", "late-harness")]}
      />,
    );
  const [helper, child] = icons(render());
  expect(helper?.tone).toBe(String(agentTone("helper")));
  expect(child?.tone).toBe(String(agentTone("late-child")));

  rememberHarnessIcons([{ id: "late-harness", iconSpec: { kind: "emoji", text: "🦊", source: "profile" } }]);
  const [, late] = icons(render());
  expect(late?.inner).toContain("🦊");
  expect(late?.tone).toBeUndefined();
});

test("a subagent row keeps its name and harness mark without a fork icon or usage counts", () => {
  const html = renderToStaticMarkup(
    <SubagentsSection
      agents={[{ ...agent("reviewer", "codex"), tokens: 107_500, toolUses: 211 }]}
      waiting={new Set()}
    />,
  );
  expect(html).toContain("reviewer");
  expect(icons(html)[0]?.inner).toBe(mark("codex"));
  expect(html).not.toContain("acpmux-agent-line__kind-icon");
  expect(html).not.toContain("acpmux-agent-line__progress");
  expect(html).not.toContain("107.5K");
  expect(html).not.toContain("211 tool uses");
});
