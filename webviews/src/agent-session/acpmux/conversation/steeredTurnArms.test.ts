// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The `stacked` and `inline` arms of turn-fold-steered (turnFoldSteered.experiment.ts): once a steered turn
// ends, its work sits under one Worked for, with no thought or call drawn loose beside it (Leo, 2026-11-22:
// "clearly there's still improper folds and stuff"; "potentially we can just stick the steered together").
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
import { isVisiblyEmptyMessage } from "./visibleMessage";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const run = (id: string, title: string) =>
  row(id, "activity", {
    toolCount: 1,
    items: [{ kind: "tool", tool: { id: `${id}-call`, title, kind: "execute", status: "completed" } }] as never,
  });
const steered = () => {
  at = 0;
  return [
    row("prompt", "user", { text: "Tidy the footer" }),
    run("run-1", "git status"),
    row("ack", "assistant", { text: "Looking at the footer now." }),
    row("steer", "user", { text: "also the header", steer: "landed" }),
    run("run-2", "rg header"),
    row("answer", "assistant", { text: "Both are tidied." }),
    row("s", "turnSummary", { status: "completed", durationMs: 4_000, toolCount: 2 }),
  ];
};
const view = (arm: string | undefined, rows = steered(), expanded: Set<string> = new Set()) => {
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = arm
    ? { "turn-fold-steered": arm }
    : {};
  return turnView(rows, expanded).filter((entry) => entry.kind !== "date" && !isVisiblyEmptyMessage(entry));
};
afterEach(() => {
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const twoSteers = () => {
  const rows = steered();
  rows.splice(
    5,
    0,
    row("ack2", "assistant", { text: "Header done." }),
    row("steer2", "user", { text: "and the sidebar", steer: "landed" }),
    run("run-3", "ls"),
  );
  return rows;
};
const ids = (entries: { kind: string; id: string }[]) => entries.map((entry) => entry.id);
const loose = (entries: { kind: string }[]) => entries.filter((entry) => entry.kind === "activity");

test("today's look is unchanged with no arm set: one Worked for per stretch, the steer between them", () => {
  expect(ids(view(undefined))).toEqual([
    "prompt",
    "worked-prompt",
    "ack",
    "superseded-steer",
    "steer",
    "worked-steer",
    "answer",
    "s",
  ]);
});

test("stacked: the steers sit under the prompt, one Worked for holds the rest, no run or reply drawn loose", () => {
  expect(ids(view("stacked"))).toEqual(["prompt", "steer", "worked-prompt", "answer", "s"]);
  expect(ids(view("stacked", twoSteers()))).toEqual(["prompt", "steer", "steer2", "worked-prompt", "answer", "s"]);
});

test("stacked, opened: the work and the reply before the steer draw inside the fold, the steer stays up top", () => {
  const open = view("stacked", steered(), new Set(["worked-prompt"]));
  expect(ids(open)).toEqual(["prompt", "steer", "worked-prompt", "run-1", "ack", "run-2", "answer", "s"]);
});

test("inline: one Worked for holds the whole turn, the steers inside it where they arrived", () => {
  expect(ids(view("inline"))).toEqual(["prompt", "worked-prompt", "answer", "s"]);
  expect(ids(view("inline", twoSteers()))).toEqual(["prompt", "worked-prompt", "answer", "s"]);
  const open = ids(view("inline", steered(), new Set(["worked-prompt"])));
  expect(open.indexOf("ack")).toBeLessThan(open.indexOf("steer"));
  expect(open.indexOf("steer")).toBeLessThan(open.indexOf("run-2"));
  expect(open.indexOf("run-2")).toBeLessThan(open.indexOf("answer"));
});

for (const arm of ["stacked", "inline"])
  test(`${arm}: closed, no call is drawn outside the fold`, () => {
    expect(loose(view(arm))).toEqual([]);
    expect(loose(view(arm, twoSteers()))).toEqual([]);
  });

test("stacked: a turn that ends right on a steer still copies the turn from its footer", () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Tidy the footer" }),
    run("run-1", "git status"),
    row("ack", "assistant", { text: "Looking." }),
    row("steer", "user", { text: "also the header", steer: "landed" }),
    row("s", "turnSummary", { status: "completed", durationMs: 4_000, toolCount: 1 }),
  ];
  const inOrder = view(undefined, rows).find((entry) => entry.id === "superseded-steer");
  const stacked = view("stacked", rows);
  expect(ids(stacked)).toEqual(["prompt", "steer", "worked-prompt", "ack", "s"]);
  const footer = stacked.find((entry) => entry.id === "s");
  expect(inOrder?.turnCopy).toBeTruthy();
  expect(footer?.turnCopy ?? footer?.text).toBeTruthy();
});
