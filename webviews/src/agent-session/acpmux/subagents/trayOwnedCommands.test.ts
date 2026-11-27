// l10n-allow-file: test commands, not shipped UI.
// A subagent's background command sits right under its owner's line in the open hat, and only there
// drops the owner's title from its own (runningTray.ts `underOwner`). Leo's recording (ask-31a1e4b192,
// 2026-11-27, "this isn't great"): the open hat listed "acpmux delivery wedged + channel stuck · wt
// new…" one line over "acpmux delivery wedged + channel stuck", a second copy of the title with the
// command it ran cut off, and the two lines apart from each other by start time.
import { expect, test } from "bun:test";
import { trayItems } from "./runningTray";
import type { Subagent } from "./subagent";
import type { BackgroundCommand } from "../session-info/processes";

const NOW = 1_794_000_000_000;
const MIN = 60_000;
const agent = (id: string, startedAt: number, parent: string | null = null): Subagent => ({
  id,
  parent,
  name: id,
  task: id,
  kind: "general-purpose",
  state: "running",
  background: true,
  startedAt,
});
const command = (id: string, startedAt: number, subagent?: string): BackgroundCommand => ({
  id,
  command: `wt new manaflow-ai/cmux lane/${id}`,
  state: "running",
  processId: `proc-${id}`,
  startedAt,
  ...(subagent ? { subagent } : {}),
});
const order = (items: ReturnType<typeof trayItems>) =>
  items.map((item) => (item.kind === "command" ? `${item.id}${item.underOwner ? "<" : ""}` : item.id));

test("an owned command sits right under its owner, after the owner's nested agents", () => {
  const items = trayItems(
    [agent("wedged", NOW - 7 * MIN), agent("child", NOW - 6 * MIN, "wedged"), agent("resolve", NOW - 1 * MIN)],
    [command("wt", NOW - 6 * MIN, "wedged"), command("dev", NOW - 3 * MIN)],
    [],
    true,
  );
  expect(order(items)).toEqual(["resolve", "dev", "wedged", "child", "wt<"]);
});

test("a command whose owner is not listed keeps its own place and the owner's title", () => {
  const done = { ...agent("gone", NOW - 9 * MIN), state: "completed" as const };
  const items = trayItems([done], [command("wt", NOW - 6 * MIN, "gone")], [], true);
  expect(order(items)).toEqual(["wt"]);
  const only = items[0]!;
  expect(only.kind === "command" && only.owner?.id).toBe("gone");
});
