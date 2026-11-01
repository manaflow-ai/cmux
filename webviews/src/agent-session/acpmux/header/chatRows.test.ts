import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { deleteChatRow, moveMachineRow } from "./chatRows";

const t = ((key: string) => key) as Parameters<typeof deleteChatRow>[1];

test("Move to machine lists the host's Cloud targets and Bring Back Local", () => {
  const moved: string[] = [];
  let back = 0;
  const row = moveMachineRow(
    {
      move: true,
      bringBack: true,
      targets: [
        { id: "a", label: "Build Mac" },
        { id: "b", label: "Review Mac" },
      ],
    },
    { moveTo: (id) => moved.push(id), bringBack: () => back++ },
    t,
  );
  expect(row?.label).toBe("chatMenu.moveToMachine");
  expect(row?.children?.map((child) => child.label)).toEqual(["Build Mac", "Review Mac", "composer.bringBackLocal"]);
  for (const child of row?.children ?? []) child.onSelect();
  expect(moved).toEqual(["a", "b"]);
  expect(back).toBe(1);
});

test("a Cloud chat's only move is named for itself, and nowhere to move draws no row", () => {
  const row = moveMachineRow(
    { move: false, bringBack: true, targets: [] },
    { moveTo: () => undefined, bringBack: () => undefined },
    t,
  );
  expect(row?.label).toBe("composer.bringBackLocal");
  expect(
    moveMachineRow(
      { move: true, bringBack: false, targets: [] },
      { moveTo: () => undefined, bringBack: () => undefined },
      t,
    ),
  ).toBeUndefined();
});

test("Delete asks through the delete dialog", () => {
  let asked = 0;
  const row = deleteChatRow(() => asked++, t);
  expect(row.key).toBe("delete");
  row.onSelect?.();
  expect(asked).toBe(1);
});

// The title's old menu rows (Rename, Fork, Move to machine, Open in's Browser, Terminal and New
// window, Archive, Delete) all stay reachable from the header's ⋮ menu once the title is plain text.
test("the header's ⋮ menu keeps every action the title menu had", () => {
  const app = readFileSync(join(import.meta.dir, "../App.tsx"), "utf8");
  const start = app.indexOf("const chatMenu = (): ChatMenuItem[] =>");
  const end = app.indexOf("\n  };\n", start);
  const chatMenu = app.slice(start, end);
  expect(start).toBeGreaterThan(-1);
  for (const needle of [
    'key: "rename"',
    "forkMenuRows(",
    "moveMachineRow(",
    "opensBesideRows(",
    'key: "newWindow"',
    "...(archive ? [archive] : [])",
    "deleteChatRow(",
  ])
    expect(chatMenu).toContain(needle);
  // The title has no menu of its own any more.
  expect(app).not.toMatch(/titleMenu|<ThreadTitle[^>]*menu=/);
});
