// The chat menu's Auto rows (autoRow.ts) and where they sit (chatRows.ts `moveMachineRow`), in the
// DOM menu and the native one (nativeMenuBindings.ts).
import { expect, test } from "bun:test";
import type { AutoSession } from "../autoSession/autoSession";
import { autoRows } from "./autoRow";
import { moveMachineRow } from "./chatRows";
import { nativeChatMenu } from "./nativeMenuBindings";

const t = ((key: string) => key) as Parameters<typeof autoRows>[2];
const auto = (over: Partial<AutoSession> = {}): AutoSession => ({
  auto: false,
  state: "local",
  here: true,
  keepInCloud: false,
  ...over,
});
const noMoves = { moveTo: () => undefined, bringBack: () => undefined };

test("a chat whose acpmux says nothing of Auto gets no row", () => {
  expect(autoRows(undefined, { setAuto: () => undefined, keepInCloud: () => undefined }, t)).toEqual([]);
  expect(moveMachineRow({ move: false, bringBack: false, targets: [] }, noMoves, t, [])).toBeUndefined();
});

test("Auto is one row that is on or off, and picking it asks for the other", () => {
  const asked: boolean[] = [];
  const run = { setAuto: (on: boolean) => asked.push(on), keepInCloud: () => undefined };
  const off = autoRows(auto(), run, t);
  expect(off.map((row) => [row.key, row.label, row.on, row.disabled])).toEqual([["auto", "auto.menu", false, false]]);
  off[0]!.onSelect();
  const on = autoRows(auto({ auto: true }), run, t);
  expect(on[0]!.on).toBe(true);
  on[0]!.onSelect();
  expect(asked).toEqual([true, false]);
});

test("while the Cloud runs the chat, Keep in Cloud is offered and Auto cannot be turned off", () => {
  const kept: boolean[] = [];
  const run = { setAuto: () => undefined, keepInCloud: (keep: boolean) => kept.push(keep) };
  const rows = autoRows(auto({ auto: true, state: "cloud", here: false }), run, t);
  expect(rows.map((row) => [row.key, row.label, row.on, row.disabled === true])).toEqual([
    ["auto", "auto.menu", true, true],
    ["keepInCloud", "auto.menu.keepInCloud", false, false],
  ]);
  rows[1]!.onSelect();
  autoRows(auto({ auto: true, state: "coming_back", here: false, keepInCloud: true }), run, t)[1]!.onSelect();
  expect(kept).toEqual([true, false]);
  // Nobody runs a parked chat: there is nothing to keep in the Cloud.
  expect(autoRows(auto({ auto: true, state: "parked", here: false }), run, t).map((row) => row.key)).toEqual(["auto"]);
});

test("the Auto rows end the chat's Cloud submenu under a line, after the places it can move", () => {
  const rows = autoRows(auto(), { setAuto: () => undefined, keepInCloud: () => undefined }, t);
  const row = moveMachineRow(
    { move: true, bringBack: false, targets: [{ id: "vm-a", label: "gpu-box", kind: "cloud" }] },
    noMoves,
    t,
    rows,
  );
  expect(row?.label).toBe("composer.moveToMenu");
  expect(row?.children?.map((child) => [child.label, child.separatorBefore === true])).toEqual([
    ["gpu-box", false],
    ["auto.menu", true],
  ]);
});

test("with nowhere to move, the submenu is the chat's Computer and holds only Auto", () => {
  const rows = autoRows(auto(), { setAuto: () => undefined, keepInCloud: () => undefined }, t);
  const row = moveMachineRow({ move: false, bringBack: false, targets: [] }, noMoves, t, rows);
  expect(row?.label).toBe("composer.computer");
  expect(row?.children?.map((child) => [child.label, child.separatorBefore === true])).toEqual([["auto.menu", false]]);
});

test("the native menu draws the same rows with their check, and a pick runs the same action", () => {
  const asked: boolean[] = [];
  const rows = autoRows(
    auto({ auto: true, state: "cloud", here: false, keepInCloud: true }),
    { setAuto: (on) => asked.push(on), keepInCloud: (keep) => asked.push(keep) },
    t,
  );
  const row = moveMachineRow({ move: false, bringBack: true, targets: [] }, noMoves, t, rows)!;
  const native = nativeChatMenu([row])!;
  expect(native.items[0]!.children).toEqual([
    { id: "moveMachine/bringBack", label: "composer.bringBackLocal", enabled: true },
    { id: "moveMachine/auto", label: "auto.menu", enabled: false, checked: true, separatorBefore: true },
    { id: "moveMachine/keepInCloud", label: "auto.menu.keepInCloud", enabled: true, checked: true },
  ]);
  // A disabled row runs nothing; Keep in Cloud turns off.
  native.invoke("moveMachine/auto");
  native.invoke("moveMachine/keepInCloud");
  expect(asked).toEqual([false]);
});
