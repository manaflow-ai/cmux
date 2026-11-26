// Leo 2026-10-30: "subagents shouldn't be tab-named the exact same as the parent". A subagent's pane
// is a tab on its chat's own session, so the app named it like the chat; the page now sends the
// subagent's own name with `chat.subagentPane`, and the app gives it to the pane's tab.
import { expect, test } from "bun:test";
import { openSubagentPane, subagentTabTitle } from "../src/agent-session/acpmux/subagents/subagentPanes";
import { agentTone } from "../src/agent-session/acpmux/subagents/agentTones";

test("the pane request carries the subagent's name, and leaves it out when there is none", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const call = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    return { opened: true };
  };
  expect(await openSubagentPane(call, "agent-1", false, "Review the tray motion diff", agentTone("agent-1"))).toBe(
    true,
  );
  expect(await openSubagentPane(call, "agent-2", true, undefined, agentTone("agent-2"))).toBe(true);
  expect(calls).toEqual([
    {
      method: "chat.subagentPane",
      params: { subagent: "agent-1", focus: false, title: "Review the tray motion diff", tone: agentTone("agent-1") },
    },
    { method: "chat.subagentPane", params: { subagent: "agent-2", focus: true, tone: agentTone("agent-2") } },
  ]);
});

// Leo, 2026-11-22: "the metadata about provenance or whatever like subagent of something. we shouldn't
// have those." A subagent with no name of its own (its name is only its id) is named by its task (the
// Agent call's description), else plainly "Subagent", never after the chat it came from.
test("a subagent's tab takes its own name, else its task, else a plain label", () => {
  const plain = "Subagent";
  expect(subagentTabTitle({ id: "a1", name: "Review the tray motion diff" }, plain)).toBe(
    "Review the tray motion diff",
  );
  expect(subagentTabTitle({ id: "a1", name: "a1", task: "Check the tray\nin detail" }, plain)).toBe("Check the tray");
  expect(subagentTabTitle({ id: "a1", name: "a1", task: "  " }, plain)).toBe(plain);
  expect(subagentTabTitle({ id: "a1", name: "a1" }, plain)).toBe(plain);
  expect(subagentTabTitle({ id: "a1", name: "   " }, plain)).toBe(plain);
  expect(subagentTabTitle(undefined, plain)).toBe(plain);
});
