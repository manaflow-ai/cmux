import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { BackgroundTasksPanel } from "../src/agent-session/acpmux/backgroundTasks/BackgroundTasksPanel";
import { AgentCard } from "../src/agent-session/acpmux/subagents/AgentCard";
import { AgentIdentity } from "../src/agent-session/acpmux/subagents/AgentIdentity";
import { AgentLine } from "../src/agent-session/acpmux/subagents/AgentLine";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";
import { Avatar } from "../src/agent-session/acpmux/subagents/SubagentGroup";
import { AgentMark } from "../src/agent-session/shared/AgentMark";
import { rememberHarnessIcons, type HarnessIconSpec } from "../src/agent-session/shared/harnessIcons";

test("a known harness keeps its shape and the same agent hue across transcript, tray and card", async () => {
  const id = "reviewer";
  const tone = agentTone(id);
  const views = [
    <Avatar
      key="avatar"
      agent={{ id, name: "Reviewer", harness: "claude", state: "completed", parent: null, startedAt: 1 }}
    />,
    <AgentLine key="line" name="Reviewer" status="done" state="Done" mark="claude" tone={tone} iconSize={14} />,
    <AgentCard key="card" name="Reviewer" identity={id} harness="claude" state="done" />,
  ];
  // AgentCard's avatar store is client-only. Mount the real components as the pane does rather
  // than asking their unrelated stores for server snapshots.
  const dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", { url: "http://localhost/" });
  const scope = globalThis as Record<string, unknown>;
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    MutationObserver: dom.window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  const saved = new Map(Object.keys(replacements).map((key) => [key, scope[key]]));
  Object.assign(scope, replacements);
  const container = dom.window.document.querySelector("main")!;
  const root = createRoot(container);
  try {
    for (const view of views) {
      await act(async () => root.render(view));
      const mark = container.querySelector("[data-identity-look=tint]");
      expect(mark?.getAttribute("data-agent-tone")).toBe(String(tone));
      expect(mark?.querySelector('[data-agent="claude"]')).not.toBeNull();
    }
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
  }
});

test("non-subagent identities keep their brand mark", () => {
  const html = renderToStaticMarkup(<AgentIdentity harness="claude" tone={2} />);
  expect(html).toContain(renderToStaticMarkup(<AgentMark agent="claude" size={14} />));
  expect(html).not.toContain("data-identity-look");
});

test.each([
  { kind: "image", mime: "image/png", data: "c3ludGhldGlj", source: "profile" },
  { kind: "emoji", text: "🦊", source: "profile" },
  { kind: "monogram", text: "RV", hue: 120, source: "profile" },
] satisfies HarnessIconSpec[])("custom $kind artwork stays intact beside its identity hue", (iconSpec) => {
  const harness = `claude-artwork-${iconSpec.kind}`;
  rememberHarnessIcons([{ id: harness, iconSpec }]);
  const html = renderToStaticMarkup(<AgentIdentity harness={harness} tone={2} look="tint" />);
  expect(html).toContain('data-agent-tone="2" data-identity-look="badge"');
  expect(html).toContain(renderToStaticMarkup(<AgentMark agent={harness} size={14} />));
  expect(html).not.toContain("mask:");
  expect(html).not.toContain("grayscale");
});

test("a working subagent keeps its spinner and the same identity ink as its finished harness mark", () => {
  const tone = agentTone("reviewer");
  for (const working of [true, false]) {
    const html = renderToStaticMarkup(
      <AgentLine
        name="Reviewer"
        status={working ? "running" : "done"}
        state={working ? "Running" : "Done"}
        mark="claude"
        tone={tone}
        working={working}
      />,
    );
    expect(html).toContain(`data-state="${working ? "running" : "done"}" data-agent-tone="${tone}"`);
    expect(html).toContain("color:var(--agent-tone-ink)");
    expect(html.includes("cv-spinner")).toBe(working);
    expect(html.includes('data-agent="claude"')).toBe(!working);
  }
});

test("Background tasks keeps group and nested-agent hues beside their harness marks", () => {
  const html = renderToStaticMarkup(
    <BackgroundTasksPanel
      groups={[
        {
          id: "agent:reviewer",
          kind: "agent",
          agentId: "reviewer",
          name: "Reviewer",
          harness: "claude",
          state: "running",
          startedAt: 1,
          total: 1,
          failed: 0,
          finished: [],
          running: [
            {
              id: "explorer",
              kind: "agent",
              agentId: "explorer",
              title: "Explorer",
              harness: "codex",
              state: "running",
            },
          ],
        },
      ]}
      onClearFinished={() => {}}
    />,
  );
  expect(html).toContain(`data-agent-tone="${agentTone("reviewer")}" data-identity-look="tint"`);
  expect(html).toContain(`data-agent-tone="${agentTone("explorer")}" data-identity-look="tint"`);
  expect(html).toContain(renderToStaticMarkup(<AgentMark agent="claude" size={14} tint />));
  expect(html).toContain(renderToStaticMarkup(<AgentMark agent="codex" size={12} tint />));
});
