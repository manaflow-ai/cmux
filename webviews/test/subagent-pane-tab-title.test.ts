// Leo 2026-10-30: "subagents shouldn't be tab-named the exact same as the parent". A subagent's pane
// is a tab on its chat's own session, so the app named it like the chat; the page now sends the
// subagent's own name with `chat.subagentPane`, and the app gives it to the pane's tab.
import { expect, test } from "bun:test";
import { openSubagentPane, subagentTabTitle } from "../src/agent-session/acpmux/subagents/subagentPanes";

test("the pane request carries the subagent's name, and leaves it out when there is none", async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const call = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    return { opened: true };
  };
  expect(await openSubagentPane(call, "agent-1", false, "Review the tray motion diff")).toBe(true);
  expect(await openSubagentPane(call, "agent-2", true)).toBe(true);
  expect(calls).toEqual([
    {
      method: "chat.subagentPane",
      params: { subagent: "agent-1", focus: false, title: "Review the tray motion diff" },
    },
    { method: "chat.subagentPane", params: { subagent: "agent-2", focus: true } },
  ]);
});

// Leo 2026-10-30: "the sidebar tab shouldn't just be named claude sr2 coord if you can just say it's
// SUbagent of sr2 coord". A subagent with no name of its own (its name is only its id) is named after
// what it is, relative to the chat.
test("a subagent's tab takes its own name, else says it is the chat's subagent", () => {
  const of = "Subagent of claude-sr2-coord";
  expect(subagentTabTitle({ id: "a1", name: "Review the tray motion diff" }, of)).toBe("Review the tray motion diff");
  expect(subagentTabTitle({ id: "a1", name: "a1" }, of)).toBe(of);
  expect(subagentTabTitle({ id: "a1", name: "   " }, of)).toBe(of);
  expect(subagentTabTitle(undefined, of)).toBe(of);
});
