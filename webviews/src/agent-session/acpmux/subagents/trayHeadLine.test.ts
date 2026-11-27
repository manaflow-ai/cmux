// l10n-allow-file: test commands, not shipped UI.
// The composer hat's one line (trayHeadKinds.ts `trayHeadLine`; Leo, 2026-11-25: "like claude code just
// has this and they tuck it at the very bottom of the transcript after the latest message").
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import type { BackgroundCommand } from "../session-info/processes";
import { finishedTrayItems, trayItems } from "./runningTray";
import { trayHeadLine } from "./trayHeadKinds";

const command = (id: string, state: BackgroundCommand["state"] = "running"): BackgroundCommand => ({
  id,
  command: `sleep ${id}`,
  state,
  processId: `proc-${id}`,
  startedAt: 1_794_000_000_000,
});
const subagent = (id: string, state = "running") => ({
  id,
  parent: null,
  name: id,
  state,
  startedAt: 1_794_000_000_000,
  ...(state === "running" ? {} : { endedAt: 1_794_000_100_000 }),
});
const none = new Set<string>();

test("it says what runs in plain words, as Claude Code's line does", () => {
  const agents = Array.from({ length: 10 }, (_, index) => subagent(`a${index}`));
  const items = trayItems(agents as never, [command("1"), command("2")], [], true);
  expect(trayHeadLine(translate, { items, finished: [], waiting: none })).toBe(
    "10 subagents working, 2 background commands running",
  );
});

test("a part at 0 is left out, and one reads in the singular", () => {
  const items = trayItems([], [command("1")], [], true);
  expect(trayHeadLine(translate, { items, finished: [], waiting: none })).toBe("1 background command running");
  const agents = trayItems([subagent("a")] as never, [], [], true);
  expect(trayHeadLine(translate, { items: agents, finished: [], waiting: none })).toBe("1 subagent working");
});

test("nothing at all says nothing", () => {
  expect(trayHeadLine(translate, { items: [], finished: [], waiting: none })).toBe("");
});

test("with nothing running, a finished background command is the completion notice", () => {
  const finished = [command("1", "completed"), command("2", "completed")].map((ended) => ({
    kind: "command" as const,
    id: ended.id,
    command: ended,
  }));
  expect(trayHeadLine(translate, { items: [], finished, waiting: none })).toBe("2 background commands finished");
});

test("what ended is not counted while something still runs, but a failure is", () => {
  const items = trayItems([subagent("a")] as never, [], [], true);
  const finished = finishedTrayItems([subagent("b", "failed"), subagent("c", "completed")] as never, []);
  expect(trayHeadLine(translate, { items, finished, waiting: none })).toBe("1 subagent working, 1 failed");
});
