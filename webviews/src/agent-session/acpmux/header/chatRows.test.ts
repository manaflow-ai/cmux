import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { deleteChatRow, moveMachineRow } from "./chatRows";
import { readMoveTargets, mergeMoveTargets, moveTargetParams } from "./moveTargets";

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
  expect(row?.label).toBe("composer.moveToMenu");
  expect(row?.children?.map((child) => child.label)).toEqual(["Build Mac", "Review Mac", "composer.bringBackLocal"]);
  for (const child of row?.children ?? []) child.onSelect();
  expect(moved).toEqual(["a", "b"]);
  expect(back).toBe(1);
});

test("Move to… on a Cloud chat lists this Mac and the other machines, and greyed targets are left out", () => {
  const moved: string[] = [];
  const row = moveMachineRow(
    {
      move: false,
      bringBack: true,
      targets: [
        { id: "local", label: "", kind: "local" },
        { id: "vm-b", label: "gpu-box", kind: "cloud" },
        { id: "vm-c", label: "busy-box", kind: "cloud", reason: "Paused" },
      ],
    },
    { moveTo: (id) => moved.push(id), bringBack: () => moved.push("bringBack") },
    t,
  );
  expect(row?.label).toBe("composer.moveToMenu");
  // This Mac is a target: Bring Back Local is not listed twice.
  expect(row?.children?.map((child) => child.label)).toEqual(["composer.thisMac", "gpu-box"]);
  for (const child of row?.children ?? []) child.onSelect();
  expect(moved).toEqual(["local", "vm-b"]);
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

test("Move to shows Auto and every connected peer with placement words and preserves Cloud labels", () => {
  const moved: string[] = [];
  const row = moveMachineRow(
    {
      move: true,
      bringBack: false,
      targets: [
        { id: "auto", label: "Auto", kind: "auto", status: "build-box · room for 5" },
        { id: "local", label: "", kind: "local" },
        { id: "cloud-1", label: "Cloud machine", kind: "cloud", status: "running" },
        { id: "build-box", label: "Build box", kind: "ssh", status: "room for 5" },
        { id: "busy-box", label: "Busy box", kind: "ssh", status: "busy" },
        { id: "hub-box", label: "Hub box", kind: "remote", reason: "Moving requires an SSH connection" },
      ],
    },
    { moveTo: (id) => moved.push(id), bringBack: () => undefined },
    t,
  );
  expect(row?.children?.map((child) => child.label)).toEqual([
    "Auto · build-box · room for 5",
    "composer.thisMac",
    "Cloud machine",
    "Build box · room for 5",
    "Busy box · busy",
    "Hub box · Moving requires an SSH connection",
  ]);
  expect(row?.children?.at(-1)?.disabled).toBe(true);
  for (const child of row?.children ?? []) child.onSelect();
  expect(moved).toEqual(["auto", "local", "cloud-1", "build-box", "busy-box"]);
});

test("Rust move targets are Auto first and preserve the existing Cloud and This Mac paths", () => {
  const local = { id: "local", label: "", kind: "local" as const };
  const cloud = { id: "cloud-id", label: "Cloud box", kind: "cloud" as const };
  const peers = readMoveTargets({
    targets: [
      { id: "auto", label: "Auto", kind: "auto", status: "Build box · room for 5", reason: null },
      { id: "cloud-peer", label: "Cloud box", kind: "ssh", status: "room for 4" },
      { id: "build", label: "Build box", kind: "ssh", status: "room for 5" },
      { id: "hub", label: "Hub", kind: "remote", reason: "Requires SSH" },
      { id: "invalid", kind: "ssh" },
    ],
  });
  const targets = mergeMoveTargets([local, cloud], peers);
  expect(targets.map((row) => row.id)).toEqual(["auto", "local", "cloud-id", "build", "hub"]);
  expect(targets[1]).toBe(local);
  expect(targets[2]).toBe(cloud);
  const moved: string[] = [];
  const row = moveMachineRow(
    { move: true, bringBack: true, targets },
    { moveTo: (id) => moved.push(id), bringBack: () => moved.push("back") },
    t,
  );
  row?.children?.find((child) => child.key === "machine:build")?.onSelect();
  row?.children?.find((child) => child.key === "machine:hub")?.onSelect();
  expect(moved).toEqual(["build"]);
  expect(row?.children?.[0]?.label).toBe("Auto · Build box · room for 5");
});

test("Cloud source keeps This Mac and Cloud moves while added peers explain the source limit", () => {
  const targets = mergeMoveTargets(
    [
      { id: "local", label: "", kind: "local" },
      { id: "another-cloud", label: "Other Cloud", kind: "cloud" },
    ],
    readMoveTargets({
      targets: [
        { id: "auto", label: "Auto", kind: "auto", reason: "Move this chat to This Mac first" },
        {
          id: "ssh",
          label: "Build box",
          kind: "ssh",
          status: "room for 5",
          reason: "Move this chat to This Mac first",
        },
      ],
    }),
  );
  const moved: string[] = [];
  const row = moveMachineRow(
    { move: true, bringBack: true, targets },
    { moveTo: (id) => moved.push(id), bringBack: () => undefined },
    t,
  );
  for (const child of row?.children ?? []) child.onSelect();
  expect(moved).toEqual(["local", "another-cloud"]);
  expect(row?.children?.[0]?.disabled).toBe(true);
});

test("move target query excludes the peer even when the host kind is local", () => {
  expect(moveTargetParams({ peer: "source-box", host: "this-mac", hostKind: "local" })).toEqual({
    source: "source-box",
    sourceKind: "local",
  });
  expect(moveTargetParams({ host: "this-mac", hostKind: "local" })).toEqual({ sourceKind: "local" });
  expect(moveTargetParams({ host: "cloud-box", hostKind: "cloud" })).toEqual({
    source: "cloud-box",
    sourceKind: "cloud",
  });
});
