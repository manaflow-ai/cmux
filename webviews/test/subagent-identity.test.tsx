import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AgentCard } from "../src/agent-session/acpmux/subagents/AgentCard";
import { AgentIdentity } from "../src/agent-session/acpmux/subagents/AgentIdentity";
import { AgentLine } from "../src/agent-session/acpmux/subagents/AgentLine";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";
import { Avatar } from "../src/agent-session/acpmux/subagents/SubagentGroup";
import { AgentMark } from "../src/agent-session/shared/AgentMark";

test("a known harness keeps its shape and the same agent hue across transcript, tray and card", () => {
  const id = "reviewer";
  const tone = agentTone(id);
  const mark = renderToStaticMarkup(<AgentMark agent="claude" size={14} tint />);
  const views = [
    <Avatar agent={{ id, name: "Reviewer", harness: "claude", state: "completed", parent: null, startedAt: 1 }} />,
    <AgentLine name="Reviewer" status="done" state="Done" mark="claude" tone={tone} iconSize={14} />,
    <AgentCard name="Reviewer" identity={id} harness="claude" state="done" />,
  ];
  for (const view of views) {
    const html = renderToStaticMarkup(view);
    expect(html).toContain(`data-agent-tone="${tone}" data-identity-look="tint"`);
    expect(html).toContain(mark);
  }
});

test("non-subagent identities keep their brand mark", () => {
  const html = renderToStaticMarkup(<AgentIdentity harness="claude" tone={2} />);
  expect(html).toContain(renderToStaticMarkup(<AgentMark agent="claude" size={14} />));
  expect(html).not.toContain("data-identity-look");
});
