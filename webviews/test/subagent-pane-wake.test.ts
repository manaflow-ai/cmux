// A subagent's pane (subagents/subagentPanes.ts) is a tab on its chat's session that the app opens
// with a one-time `subagent:<id>` reveal. When its hidden page lets go (the person leaves the
// workspace) or the app quits, the page built again gets no reveal: the wake state carries the
// subagent the pane showed (App.tsx `subagentPaneNow`), and the page reads it back, so the pane never
// comes back as the chat's own (pane/paneSnapshot.ts).
import { expect, test } from "bun:test";
import { readWake } from "../src/agent-session/acpmux/pane/wake";

test("a wake state hands back the subagent its pane showed", () => {
  expect(readWake({ subagentPane: "agent-1" })?.subagentPane).toBe("agent-1");
  expect(readWake({ subagentPane: "cmux:background-tasks" })?.subagentPane).toBe("cmux:background-tasks");
});

test("a chat's own pane, or a malformed value, names no subagent", () => {
  expect(readWake({ atLatest: true })?.subagentPane).toBeUndefined();
  expect(readWake({ subagentPane: "" })?.subagentPane).toBeUndefined();
  expect(readWake({ subagentPane: 7 })?.subagentPane).toBeUndefined();
});
