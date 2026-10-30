// A click on a subagent (a group line, a card row, the agents pill) opened a split right of the
// chat even with the summary card's switch off, so subagents kept landing in splits (Austin
// 2026-10-21, nightly 3955ea8). With the switch off a click shows the subagent in the chat's own
// pane; only with it on does a click ask the app for a pane (subagents/subagentPanes.ts).
import { expect, test } from "bun:test";
import { showSubagent } from "../src/agent-session/acpmux/subagents/subagentPanes";

/// What showing subagent "reviewer" did: the app calls it made and the views it showed here.
async function show(options: { panes: boolean; inSubagentPane?: boolean; focus?: boolean; opened?: boolean }) {
  const calls: string[] = [];
  const here: string[] = [];
  await showSubagent(
    async (method) => {
      calls.push(method);
      return { opened: options.opened ?? true };
    },
    "reviewer",
    options.focus ?? true,
    { panes: options.panes, inSubagentPane: options.inSubagentPane ?? false, here: (id) => here.push(id) },
  );
  return { calls, here };
}

test("with the switch off, a click shows the subagent in the chat and opens no pane", async () => {
  expect(await show({ panes: false })).toEqual({ calls: [], here: ["reviewer"] });
});

test("with the switch on, a click asks the app for the subagent's pane", async () => {
  expect(await show({ panes: true })).toEqual({ calls: ["chat.subagentPane"], here: [] });
});

test("with the switch on and a host that opens none, a click shows it in the chat", async () => {
  expect(await show({ panes: true, opened: false })).toEqual({ calls: ["chat.subagentPane"], here: ["reviewer"] });
});

test("a subagent's own pane shows other subagents in place, never in more panes", async () => {
  expect(await show({ panes: true, inSubagentPane: true })).toEqual({ calls: [], here: ["reviewer"] });
});
