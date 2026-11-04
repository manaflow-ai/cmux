// l10n-allow-file: test fixture subagent names and replies, not shipped UI.
// The running tray, richer (Leo, 2026-11-03, on Claude Code Desktop's parallel agents: "yo wtf i
// want this kind of feature in cmux-next too", then "Tray only, richer"): each running line says
// what its agent did last, and an agent that stopped to wait on background work of its own (acpmux's
// interim cause) stays a live tray line, its clock going, with no "Subagent finished" line yet.
import { expect, test } from "bun:test";
import { setPaneLanguage, translate } from "../src/agent-session/acpmux/i18n";
import { awaitsOwnWork, SUBAGENTS, type Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { finishedTrayItems, trayItems, withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";
import { lastSaidLine, latestLine } from "../src/agent-session/acpmux/subagents/trayDetail";
import { elapsed, groupElapsed, ticking } from "../src/agent-session/acpmux/subagents/SubagentGroup";
import { subagentStatus, subagentStateText } from "../src/agent-session/acpmux/summary/SubagentStatusList";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

setPaneLanguage("en");
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");

const agent = (id: string, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: id,
  task: `Task ${id}`,
  state: "running",
  startedAt: 1_000,
  ...fields,
});
const interim = { turn: "bg-1", weight: "silent" as const, interim: true as const };

test("an interim end leaves the agent waiting on its own work, until a final report replaces it", () => {
  const waiting = agent("w", { state: "completed", endedAt: 5_000, reaction: interim });
  expect(awaitsOwnWork(waiting)).toBe(true);
  expect(awaitsOwnWork({ ...waiting, reaction: { turn: "bg-2", weight: "result" } })).toBe(false);
  expect(awaitsOwnWork({ ...waiting, state: "failed" })).toBe(false);
  expect(subagentStatus(waiting, new Set())).toBe("idle");
  expect(subagentStateText(t, waiting, new Set())).toBe("Waiting on its background work");
  // Its clock keeps going.
  expect(elapsed(waiting, 65_000)).toBe(64_000);
  expect(elapsed({ ...waiting, reaction: undefined }, 65_000)).toBe(4_000);
  // So do its group's time and the clocks that tick for it (the card, the Session Info list).
  const done = agent("d", { state: "completed", endedAt: 6_000 });
  expect(ticking(waiting)).toBe(true);
  expect(ticking(done)).toBe(false);
  expect(groupElapsed([waiting, done], 65_000)).toBe(64_000);
  expect(groupElapsed([{ ...waiting, reaction: undefined }, done], 65_000)).toBe(5_000);
});

test("the tray lists it with the running work, and the transcript keeps no finished line for it yet", () => {
  const waiting = agent("w", { state: "completed", endedAt: 5_000, background: true, reaction: interim });
  const done = agent("d", { state: "completed", endedAt: 6_000 });
  const items = trayItems([waiting, done], [], [], false);
  expect(items.map((item) => item.id)).toEqual(["w"]);
  expect(finishedTrayItems([waiting, done], []).map((item) => item.id)).toEqual(["d"]);
  const rows: AcpmuxRow[] = [
    { id: "u", version: 1, at: 0, kind: "user", text: "go" },
    { id: "g", version: 1, at: 1_000, kind: SUBAGENTS, subagents: [waiting, done] },
    { id: "a", version: 1, at: 9_000, kind: "assistant", text: "ok" },
  ];
  const lines = withSubagentLines(rows).filter((row) => row.kind === SUBAGENT_DONE);
  expect(lines.map((row) => row.subagents?.[0]?.id)).toEqual(["d"]);
});

test("a line's latest words: its step while it runs, its last words while it waits on its own work", () => {
  expect(lastSaidLine("## Report\n\n- first\n- **Fix:** reuse the upload\n\n")).toBe("Fix: reuse the upload");
  expect(lastSaidLine("   \n---\n")).toBeUndefined();
  const running = agent("r", { action: "Read warm-sources.json", lastMessage: "Earlier words" });
  expect(latestLine(t, running, false)).toBe("Read warm-sources.json");
  // A shell step reads in words ("Running git …"), never the raw command line.
  const shell = latestLine(t, { ...running, action: "git log --oneline", actionShell: true }, false);
  expect(shell).not.toBe("git log --oneline");
  expect(shell).toContain("git");
  expect(latestLine(t, agent("q", { lastMessage: "Started the run." }), false)).toBe("Started the run.");
  expect(latestLine(t, { ...running, lastMessage: "Started the notarization run." }, true)).toBe(
    "Started the notarization run.",
  );
  expect(latestLine(t, agent("e"), false)).toBeUndefined();
});
