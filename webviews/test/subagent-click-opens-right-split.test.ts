// A subagent the person opens (a Session Info or card row, a group line, the agents pill) opens in
// its pane right of the chat, whatever the summary card's switch says (Leo, 2026-11-02: "WHEN I OPEN
// A SUBAGENT IT SHOULD GO TO THE RIGHT SPLIT AREA"): the chat's own pane, and so its Session Info,
// stay on the chat. The switch (off by default, Austin 2026-10-21) still governs the panes nobody
// asked for, the ones new subagents open by themselves (subagents/subagentPanes.ts).
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
    {
      panes: options.panes,
      inSubagentPane: options.inSubagentPane ?? false,
      here: (id) => here.push(id),
      beforeOpen: () => calls.push("tail.handover"),
    },
  );
  return { calls, here };
}

test("with the switch off, a click opens the subagent's pane and leaves the chat's view alone", async () => {
  expect(await show({ panes: false })).toEqual({ calls: ["tail.handover", "chat.subagentPane"], here: [] });
});

test("with the switch off and a host that opens none, a click shows it in the chat", async () => {
  expect(await show({ panes: false, opened: false })).toEqual({
    calls: ["tail.handover", "chat.subagentPane"],
    here: ["reviewer"],
  });
});

test("with the switch on, a click asks the app for the subagent's pane", async () => {
  expect(await show({ panes: true })).toEqual({ calls: ["tail.handover", "chat.subagentPane"], here: [] });
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  await showSubagent(
    async (method, params) => {
      calls.push({ method, params });
      return { opened: true };
    },
    "reviewer",
    true,
    { panes: true, inSubagentPane: false, here: () => {}, title: "Review the tray motion diff" },
  );
  expect(calls).toEqual([
    {
      method: "chat.subagentPane",
      params: { subagent: "reviewer", focus: true, title: "Review the tray motion diff" },
    },
  ]);
});

test("with the switch on and a host that opens none, a click shows it in the chat", async () => {
  expect(await show({ panes: true, opened: false })).toEqual({
    calls: ["tail.handover", "chat.subagentPane"],
    here: ["reviewer"],
  });
});

test("a subagent's own pane shows other subagents in place, never in more panes", async () => {
  expect(await show({ panes: true, inSubagentPane: true })).toEqual({ calls: [], here: ["reviewer"] });
});

test("background discovery with panes off opens no pane and leaves the shown chat alone", async () => {
  expect(await show({ panes: false, focus: false })).toEqual({ calls: [], here: [] });
});

test("background discovery with panes on hands over the tail before opening its pane", async () => {
  expect(await show({ panes: true, focus: false })).toEqual({
    calls: ["tail.handover", "chat.subagentPane"],
    here: [],
  });
});
