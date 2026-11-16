// l10n-allow-file: test commands, not shipped UI.
// The folded hat's header holds its lead and its clock while its work changes (trayHeadOrder.ts).
// The sequence of Leo's recording (2026-11-11, his NIGHTLY, the end of a turn): 61 background
// commands, the oldest a `glaeda-gh wait` started 1h 40m before; seven of the oldest end, then eight
// new ones start. Before: the clock read 1h 40m 4s, then 1h 27m 28s (back 12m 36s as the oldest
// ended), then 1h 40m 20s, and the lead swapped to each newest command.
import { expect, test } from "bun:test";
import { longestRunningFirst, runSince } from "./trayHeadOrder";
import { trayItems, type TrayItem } from "./runningTray";
import type { BackgroundCommand } from "../session-info/processes";

const NOW = 1_794_000_000_000;
const MIN = 60_000;
const command = (index: number, startedAt: number): BackgroundCommand => ({
  id: `cmd-${index}`,
  command: `glaeda-gh wait run ${index} --timeout 2700`,
  state: "running",
  processId: `proc-${index}`,
  startedAt,
});
const lead = (items: readonly TrayItem[]) => {
  const first = longestRunningFirst(items)[0];
  return first?.kind === "command" ? first.command.id : undefined;
};

test("a new command never takes the lead, and the clock never goes back", () => {
  // 61 running, the oldest 100 minutes in, the rest spread over the last 90.
  let commands = Array.from({ length: 61 }, (_, index) => command(index, NOW - (index === 0 ? 100 : 90 - index) * MIN));
  let items = trayItems([], commands, [], true);
  let since = runSince(undefined, items);
  const clocks = [since];
  const leads = [lead(items)];
  // Seven of the oldest end, the oldest among them.
  commands = commands.slice(7);
  items = trayItems([], commands, [], true);
  since = runSince(since, items);
  clocks.push(since);
  leads.push(lead(items));
  // Eight new ones start, one at a time.
  for (let index = 61; index < 69; index++) {
    commands = [...commands, command(index, NOW + (index - 60) * 1000)];
    items = trayItems([], commands, [], true);
    since = runSince(since, items);
    clocks.push(since);
    leads.push(lead(items));
  }
  // The clock is the run's: it never moves after the first read.
  expect(new Set(clocks)).toEqual(new Set([NOW - 100 * MIN]));
  // The lead changes only when it ends (the oldest left with the first seven), never for a newcomer.
  expect(leads[0]).toBe("cmd-0");
  expect(new Set(leads.slice(1))).toEqual(new Set(["cmd-7"]));
});

test("a run that empties starts its clock afresh", () => {
  const first = trayItems([], [command(1, NOW - 50 * MIN)], [], true);
  const since = runSince(undefined, first);
  expect(since).toBe(NOW - 50 * MIN);
  expect(runSince(since, [])).toBeUndefined();
  const next = trayItems([], [command(2, NOW - MIN)], [], true);
  expect(runSince(runSince(since, []), next)).toBe(NOW - MIN);
});

test("an item with no start time goes after those with one, in list order", () => {
  const items = trayItems([], [{ ...command(1, NOW), startedAt: undefined }, command(2, NOW - MIN)], [], true);
  expect(longestRunningFirst(items).map((item) => item.id)).toEqual(["cmd-2", "cmd-1"]);
});
