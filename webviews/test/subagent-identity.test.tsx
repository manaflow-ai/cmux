import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { BackgroundTasksPanel } from "../src/agent-session/acpmux/backgroundTasks/BackgroundTasksPanel";
import { AgentCard } from "../src/agent-session/acpmux/subagents/AgentCard";
import { AgentIdentity } from "../src/agent-session/acpmux/subagents/AgentIdentity";
import { AgentLine } from "../src/agent-session/acpmux/subagents/AgentLine";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";
import { Avatar } from "../src/agent-session/acpmux/subagents/SubagentGroup";
import { AgentMark } from "../src/agent-session/shared/AgentMark";
import { rememberHarnessIcons, type HarnessIconSpec } from "../src/agent-session/shared/harnessIcons";

test("a known harness keeps its shape and the same agent hue across transcript, tray and card", () => {
  const id = "reviewer";
  const tone = agentTone(id);
  const views = [
    <Avatar agent={{ id, name: "Reviewer", harness: "claude", state: "completed", parent: null, startedAt: 1 }} />,
    <AgentLine name="Reviewer" status="done" state="Done" mark="claude" tone={tone} iconSize={14} />,
    <AgentCard name="Reviewer" identity={id} harness="claude" state="done" />,
  ];
  for (const view of views) {
    const html = renderToStaticMarkup(view);
    expect(html).toContain(`data-agent-tone="${tone}" data-identity-look="tint"`);
    // The identity wrapper owns the hue; the SVG's generated attributes can differ by caller
    // (card/avatar size and React's serialization), so assert the shared harness mark itself.
    expect(html).toContain('data-agent="claude"');
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
