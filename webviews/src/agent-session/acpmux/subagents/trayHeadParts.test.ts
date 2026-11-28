// l10n-allow-file: test commands, not shipped UI.
// The running tray header's kinds (trayHeadKinds.ts `trayHeadParts`): Leo, 2026-11-21, on a coordinator's
// tray that read "pgrep · head · ps" folded and "1 message · 1 wait" open: the open header "almost
// makes more sense to have at baseline", each kind with its icon to hover across.
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import { trayHead, trayHeadParts, trayHeadForms, trayHeadGroups } from "./trayHeadKinds";
import { trayItems, finishedTrayItems } from "./runningTray";
import type { BackgroundCommand } from "../session-info/processes";

const command = (id: string, line: string): BackgroundCommand => ({
  id,
  command: line,
  state: "running",
  processId: `proc-${id}`,
  startedAt: 1_794_000_000_000,
});

const commands = [
  command("send", 'acpmux send studio-mac/review "status?"'),
  command("wait", "gh pr checks 1234 --watch"),
];

test("each kind has its mark, its count and the items it counts", () => {
  const items = trayItems([], commands, [], true);
  const parts = trayHeadParts(translate, { items, finished: [], waiting: new Set() });
  expect(parts.map((part) => [part.key, part.icon, part.text, part.items.length])).toEqual([
    ["sends", "agent.chat", "1 message", 1],
    ["waits", "history", "1 wait", 1],
  ]);
});

test("the kinds read as the counts do", () => {
  const items = trayItems([], [...commands, command("ps", "pgrep -f nightly | head -3; ps -o etime= -p 1")], [], true);
  const args = { items, finished: [], waiting: new Set<string>() };
  const head = trayHead(translate, { ...args, working: true, chatHarness: "claude", arm: "kinds" });
  expect(
    trayHeadParts(translate, args)
      .map((part) => part.text)
      .join(" · "),
  ).toBe(head.text);
});

test("nothing running draws no kinds", () => {
  expect(trayHeadParts(translate, { items: [], finished: [], waiting: new Set() })).toEqual([]);
});

// The `tally` arm (trayFoldHead.experiment.ts; Leo, 2026-11-23: "just listing the # of each type of
// ongoing thing would be better. symbol for subagents, potentially per harness"; "state can fucking
// only be relevant when you may need to investigate/take action").
test("the tally counts subagents per harness family and keeps only the ended work that needs the person", () => {
  const subagent = (id: string, harness: string | undefined, state = "running") => ({
    id,
    parent: null,
    name: id,
    state,
    startedAt: 1_794_000_000_000,
    ...(harness ? { harness } : {}),
    ...(state === "running" ? {} : { endedAt: 1_794_000_100_000 }),
  });
  const items = trayItems(
    [subagent("a", "claude"), subagent("b", undefined), subagent("c", "codex-cli"), subagent("d", "codex")],
    commands,
    [],
    true,
  );
  const finished = finishedTrayItems([subagent("e", "claude", "completed"), subagent("f", "claude", "failed")], []);
  const parts = trayHeadParts(translate, { items, finished, waiting: new Set() }, true, "claude");
  expect(parts.map((part) => [part.key, part.items.length, part.harness])).toEqual([
    ["agents:claude", 2, "claude"],
    ["agents:codex", 2, "codex-cli"],
    ["sends", 1, undefined],
    ["waits", 1, undefined],
    ["failed", 1, undefined],
  ]);
  // The words stay for the hover and a reader, never "running".
  expect(parts.map((part) => part.text)).toEqual(["2 subagents", "2 subagents", "1 message", "1 wait", "1 failed"]);
});

test("the tally of only finished, fine work is empty, so the header keeps its own", () => {
  const done = finishedTrayItems(
    [{ id: "e", parent: null, name: "e", state: "completed", startedAt: 1, endedAt: 2 }],
    [],
  );
  expect(done.length).toBe(1);
  expect(trayHeadParts(translate, { items: [], finished: done, waiting: new Set() }, true)).toEqual([]);
});

// The `summary` arm's words (trayFoldHead.experiment.ts; Leo, 2026-11-23: "x subagents running y
// commands running etc with full text when you have space and it gradually shrinks when there is none").
test("each kind's long, short and count forms; a state kind is its state already", () => {
  const subagent = (id: string, state = "running") => ({
    id,
    parent: null,
    name: id,
    state,
    startedAt: 1_794_000_000_000,
    ...(state === "running" ? {} : { endedAt: 1_794_000_100_000 }),
  });
  const items = trayItems([subagent("a"), subagent("b")], [...commands, command("misc", "ls -la")], [], true);
  const finished = finishedTrayItems([subagent("f", "failed")], []);
  const parts = trayHeadParts(translate, { items, finished, waiting: new Set() }, true, "claude");
  expect(parts.map((part) => trayHeadForms(translate, part))).toEqual([
    { long: "2 subagents running", short: "2 subagents", count: "2" },
    { long: "1 message running", short: "1 message", count: "1" },
    { long: "1 wait running", short: "1 wait", count: "1" },
    { long: "1 command running", short: "1 command", count: "1" },
    { long: "1 failed", short: "1 failed", count: "1" },
  ]);
});

// The `groups` arm (trayFoldHead.experiment.ts; Leo, 2026-11-24 00:18Z: "the simplest view is just...
// subagents. other background things. boom. waits, etc, they're just normal tool calls that are
// backgrounded instead of dozesns of possible different buttons").
test("the groups count subagents and every other backgrounded call, then only what needs the person", () => {
  const subagent = (id: string, state = "running", harness?: string) => ({
    id,
    parent: null,
    name: id,
    state,
    startedAt: 1_794_000_000_000,
    ...(harness ? { harness } : {}),
    ...(state === "running" ? {} : { endedAt: 1_794_000_100_000 }),
  });
  const items = trayItems(
    [subagent("a"), subagent("b", "running", "codex"), subagent("c")],
    [...commands, command("misc", "ls -la")],
    [],
    true,
  );
  const finished = finishedTrayItems([subagent("f", "failed"), subagent("d", "completed")], []);
  const parts = trayHeadGroups(translate, { items, finished, waiting: new Set() }, "claude");
  // Two of the three run on the chat's harness: the group draws its mark, not the Codex one.
  expect(parts[0]!.harness).toBe("claude");
  expect(parts.map((part) => [part.key, part.items.length, part.tone])).toEqual([
    ["agents", 3, undefined],
    ["background", 3, undefined],
    ["failed", 1, "failed"],
  ]);
  expect(parts.map((part) => trayHeadForms(translate, part))).toEqual([
    { long: "3 subagents", short: "3 subagents", count: "3" },
    { long: "3 tasks in background", short: "3 tasks", count: "3" },
    { long: "1 failed", short: "1 failed", count: "1" },
  ]);
  // The words never say running: running needs no text.
  expect(parts.some((part) => /running/i.test(trayHeadForms(translate, part).long))).toBe(false);
});

test("one background call is one task; nothing running draws no groups", () => {
  const one = trayHeadGroups(translate, {
    items: trayItems([], [commands[1]!], [], true),
    finished: [],
    waiting: new Set(),
  });
  expect(one.map((part) => trayHeadForms(translate, part).long)).toEqual(["1 task in background"]);
  expect(trayHeadGroups(translate, { items: [], finished: [], waiting: new Set() })).toEqual([]);
});
