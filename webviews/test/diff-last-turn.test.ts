// l10n-allow-file: test fixture paths, not shipped UI.
// The diff tab's Last turn (D1, D2): a chat's edited-files card opens the diff tab on that turn,
// at the row's file, and the header's Changes offers the chat's latest turn in the scope menu.
//
// Before: the card opened the chat folder's whole branch diff (or the overlay in the chat), the
// tab had no turn scope, and its menu listed a Last turn row that could never be picked.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { latestTurnCheckpointPair, turnCheckpointPair } from "../src/agent-session/acpmux/changes/turnCheckpointSource";
import { repositoryFile, viewChangesTurn } from "../src/agent-session/acpmux/turnChanges/viewChanges";
import { sourceMenuModel } from "../src/toolbar-model";
import { validDiffSource } from "../src/diff-viewer/session";
import { revealItemId } from "../src/diff-viewer/reveal";
import type { DiffItem } from "../src/diff-stream";

const ROOT = "/Users/dev/app";
let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, kind, version: 1, at: (at += 1_000), ...extra }) as AcpmuxRow;

const chat = (): AcpmuxRow[] => [
  row("u1", "user", { text: "Fix the parser" }),
  row("a1", "activity"),
  row("s1", "turnSummary", { status: "completed", checkpoint: { from: "cp-1", to: "cp-2" } }),
  row("u2", "user", { text: "Now the tests" }),
  row("a2", "activity"),
  row("s2", "turnSummary", { status: "completed", checkpoint: { from: "cp-3", to: "cp-4" } }),
];

test("a card opens its own turn's checkpoint pair, at the row's file in the repository", () => {
  const rows = chat();
  expect(viewChangesTurn(rows, "a1", `${ROOT}/src/parse.ts`, ROOT, ROOT)).toEqual({
    from: "cp-1",
    to: "cp-2",
    file: "src/parse.ts",
    show: true,
  });
  // View changes (no row) opens the turn at its top.
  expect(viewChangesTurn(rows, "a2", undefined, ROOT, ROOT)).toEqual({ from: "cp-3", to: "cp-4", show: true });
});

test("a turn with no checkpoint pair opens no turn (the folder's diff, as before)", () => {
  const rows = [
    row("u", "user", { text: "x" }),
    row("a", "activity"),
    row("s", "turnSummary", { status: "completed" }),
    row("u-live", "user", { text: "y" }),
    row("a-live", "activity"),
  ];
  // An agent that records none, and a turn still running.
  expect(viewChangesTurn(rows, "a", undefined, ROOT, ROOT)).toBeUndefined();
  expect(turnCheckpointPair(rows, "a-live")).toBeUndefined();
  // acpmux could not take the first checkpoint.
  const noStart = [
    row("u", "user"),
    row("s", "turnSummary", { status: "completed", checkpoint: { from: null, to: "cp-9" } }),
  ];
  expect(turnCheckpointPair(noStart, "u")).toBeUndefined();
});

test("the header offers the latest ended turn, not one still running", () => {
  const rows = chat();
  expect(latestTurnCheckpointPair(rows)).toEqual({ from: "cp-3", to: "cp-4" });
  expect(latestTurnCheckpointPair([...rows, row("u3", "user", { text: "And docs" }), row("a3", "activity")])).toEqual({
    from: "cp-3",
    to: "cp-4",
  });
  expect(latestTurnCheckpointPair([row("u", "user")])).toBeUndefined();
});

test("a row's path becomes a path in the repository, or none outside it", () => {
  expect(repositoryFile("src/a.ts", ROOT, `${ROOT}/packages/web`)).toBe("packages/web/src/a.ts");
  expect(repositoryFile("../shared/b.ts", ROOT, `${ROOT}/packages/web`)).toBe("packages/shared/b.ts");
  expect(repositoryFile(`${ROOT}/./c.ts`, ROOT, ROOT)).toBe("c.ts");
  expect(repositoryFile("/tmp/l-setup.txt", ROOT, ROOT)).toBeUndefined();
  expect(repositoryFile("../../outside.ts", ROOT, ROOT)).toBeUndefined();
  expect(repositoryFile("~/code/app/d.ts", ROOT, ROOT)).toBeUndefined();
  expect(repositoryFile(ROOT, ROOT, ROOT)).toBeUndefined();
  expect(repositoryFile(`${ROOT}-other/e.ts`, ROOT, ROOT)).toBeUndefined();
  // git names the root with links resolved; the chat may not.
  expect(repositoryFile("f.ts", "/private/tmp/app", "/tmp/app")).toBe("f.ts");
  expect(repositoryFile("/tmp/app/g.ts", "/private/tmp/app", "/tmp/app")).toBe("g.ts");
});

const menu = (sourceOptions: unknown, active: Parameters<typeof sourceMenuModel>[0]["activeSource"]) =>
  sourceMenuModel({
    sourceOptions,
    repoRoot: ROOT,
    activeSource: active,
    typedTransport: true,
    isValidSource: validDiffSource,
  });
const TURN = { kind: "patch", path: "/turn.patch" } as const;

test("the scope menu shows Last turn only when a chat opened the tab", () => {
  const branch = { kind: "branch", repoRoot: ROOT, baseRef: "origin/main" } as const;
  const ids = (model: ReturnType<typeof sourceMenuModel>) => model.sections.flat().map((entry) => entry.id);
  // A tab from the palette, a key or the CLI: no chat, no Last turn row.
  expect(ids(menu(undefined, branch))).not.toContain("last-turn");
  // A chat's tab lists it, and picking it opens the turn's patch.
  const offered = menu([{ value: "last-turn", sessionSource: TURN }], branch);
  expect(offered.sections[0]).toEqual([
    { id: "last-turn", labelKey: "sourceLastTurn", target: { kind: "session", source: TURN }, checked: false },
  ]);
  expect(offered.selected?.id).toBe("branch");
  // A tab a card opened shows it checked.
  expect(menu([{ value: "last-turn", sessionSource: TURN }], TURN).selected?.id).toBe("last-turn");
});

test("the tab opens at the row's file: the exact path, else the one file ending with it", () => {
  const item = (id: string, name: string) => ({ id, fileDiff: { name } }) as unknown as DiffItem;
  const items = [
    item("1", "src/a.ts"),
    item("2", "packages/web/src/b.ts"),
    item("3", "lib/c.ts"),
    item("4", "app/lib/c.ts"),
  ];
  expect(revealItemId(items, "src/a.ts")).toBe("1");
  expect(revealItemId(items, "src/b.ts")).toBe("2");
  // Two files end with it: none is guessed.
  expect(revealItemId(items, "c.ts")).toBeUndefined();
  expect(revealItemId(items, "lib/c.ts")).toBe("3");
  expect(revealItemId(items, "missing.ts")).toBeUndefined();
});
