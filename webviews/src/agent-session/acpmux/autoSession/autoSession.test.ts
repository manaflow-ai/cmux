// Auto mode's row field and what the pane says about it (autoSession.ts, leftover.ts,
// plans/cmux-next/auto-mode/DESIGN.md). A row without the field is an acpmux that predates Auto:
// nothing new is drawn or offered for it.
import { expect, test } from "bun:test";
import {
  autoLine,
  autoSessionOf,
  autoUnderHeader,
  autoUnsupported,
  heldInCloud,
  type AutoSession,
} from "./autoSession";
import { leftoverShown } from "./leftover";
import { translate } from "../i18n";
import { sessionEntry, sessionPlace } from "../sessionList";

const auto = (over: Partial<AutoSession> = {}): AutoSession => ({
  auto: true,
  state: "local",
  here: true,
  keepInCloud: false,
  ...over,
});

test("a row without autoSession, or with one that is not Auto's, reads as no Auto at all", () => {
  expect(autoSessionOf(undefined)).toBeUndefined();
  expect(autoSessionOf(null)).toBeUndefined();
  expect(autoSessionOf("cloud")).toBeUndefined();
  expect(autoSessionOf([])).toBeUndefined();
  expect(autoSessionOf({ state: "cloud" })).toBeUndefined();
  expect(autoLine(undefined, true)).toBeUndefined();
  expect(autoUnderHeader(undefined, true)).toBe(false);
  expect(heldInCloud(undefined)).toBe(false);
});

test("the row's fields are read as the contract names them", () => {
  expect(
    autoSessionOf({ auto: true, state: "coming_back", here: false, keepInCloud: true, blocked: "offline" }),
  ).toEqual({ auto: true, state: "coming_back", here: false, keepInCloud: true, blocked: "offline" });
  // A chat not on Auto still carries the field on an acpmux that knows Auto.
  expect(autoSessionOf({ auto: false, state: "local", here: true, keepInCloud: false })).toEqual({
    auto: false,
    state: "local",
    here: true,
    keepInCloud: false,
  });
});

test("a word a newer acpmux adds draws nothing rather than something wrong", () => {
  expect(autoSessionOf({ auto: true, state: "migrating", blocked: "quota" })).toEqual({
    auto: true,
    state: "local",
    here: true,
    keepInCloud: false,
  });
  // `here` unsaid: this Mac's only while the Cloud does not run the chat.
  expect(autoSessionOf({ auto: true, state: "cloud" })?.here).toBe(false);
});

test("the kept changes are counted from a number or from the list of their paths", () => {
  expect(autoSessionOf({ auto: true, leftover: { files: 3 } })?.leftover).toEqual({ files: 3 });
  expect(autoSessionOf({ auto: true, leftover: { files: ["a.ts", "b.ts"] } })?.leftover).toEqual({ files: 2 });
  expect(autoSessionOf({ auto: true, leftover: {} })?.leftover).toEqual({ files: 0 });
  expect(autoSessionOf({ auto: true })?.leftover).toBeUndefined();
});

test("an unchanged row keeps the object the pane already holds", () => {
  const first = autoSessionOf({ auto: true, state: "cloud", here: false, leftover: { files: 1 } });
  expect(autoSessionOf({ auto: true, state: "cloud", here: false, leftover: { files: ["x"] } }, first)).toBe(first!);
  expect(autoSessionOf({ auto: true, state: "resuming", here: false }, first)).not.toBe(first!);
});

test("Keep in Cloud applies only while the Cloud runs the chat", () => {
  expect(heldInCloud(auto({ state: "cloud", here: false }))).toBe(true);
  expect(heldInCloud(auto({ state: "resuming", here: false }))).toBe(true);
  expect(heldInCloud(auto({ state: "coming_back", here: false }))).toBe(true);
  expect(heldInCloud(auto({ state: "parked", here: false }))).toBe(false);
  expect(heldInCloud(auto())).toBe(false);
  expect(heldInCloud(auto({ auto: false, state: "cloud", here: false }))).toBe(false);
});

test("each state says its one line, and a chat this Mac runs says nothing", () => {
  expect(autoLine(auto(), false)).toBeUndefined();
  expect(autoLine(auto({ state: "cloud", here: false }), false)).toEqual({ kind: "cloud" });
  expect(autoLine(auto({ state: "resuming", here: false }), false)).toEqual({ kind: "resuming" });
  expect(autoLine(auto({ state: "coming_back", here: false }), false)).toEqual({ kind: "comingBack" });
  // Auto off: the chat is this Mac's, whatever a stale state says.
  expect(autoLine(auto({ auto: false, state: "cloud" }), true)).toBeUndefined();
});

test("a chat nobody runs says nothing until the person sends, then Resuming", () => {
  const parked = auto({ state: "parked", here: false });
  expect(autoLine(parked, false)).toBeUndefined();
  expect(autoUnderHeader(parked, false)).toBe(false);
  expect(autoLine(parked, true)).toEqual({ kind: "resuming" });
  expect(autoUnderHeader(parked, true)).toBe(true);
});

test("what stops Auto comes before where the chat runs", () => {
  for (const blocked of ["no_machine", "too_large", "offline"] as const)
    expect(autoLine(auto({ blocked }), false)).toEqual({ kind: "blocked", blocked });
  expect(autoLine(auto({ state: "cloud", here: false, blocked: "offline" }), false)).toEqual({
    kind: "blocked",
    blocked: "offline",
  });
});

test("the kept-changes notice stays under the header after Auto is turned off", () => {
  expect(autoUnderHeader(auto({ auto: false, leftover: { files: 2 } }), false)).toBe(true);
  expect(autoUnderHeader(auto({ auto: false }), false)).toBe(false);
});

test("only an acpmux that does not know the method is unsupported; a host refusal is a failure", () => {
  expect(autoUnsupported({ code: -32601, message: "Method not found" })).toBe(true);
  expect(autoUnsupported({ code: -32601, data: { origin: "native" } })).toBe(false);
  expect(autoUnsupported({ code: 409, data: { code: "auto.held_in_cloud" } })).toBe(false);
  expect(autoUnsupported(new Error("closed"))).toBe(false);
  expect(autoUnsupported(undefined)).toBe(false);
});

test("Show's answer lists paths, given as text or as records", () => {
  expect(leftoverShown({ files: ["src/a.ts", { path: "src/b.ts" }, 7, { path: "" }], patch: "diff --git" })).toEqual({
    files: ["src/a.ts", "src/b.ts"],
    patch: "diff --git",
  });
  expect(leftoverShown({})).toEqual({ files: [] });
  expect(leftoverShown(null)).toEqual({ files: [] });
});

test("a chat list row carries Auto, and one the Cloud runs is placed in the Cloud", () => {
  const row = { sessionId: "s1", cwd: "/work/app", title: "Fix build", harness: "claude" };
  expect(sessionEntry(row).autoSession).toBeUndefined();
  expect(sessionPlace(sessionEntry(row))).toBeUndefined();
  const held = sessionEntry({ ...row, autoSession: { auto: true, state: "cloud", here: false, keepInCloud: false } });
  expect(held.autoSession).toEqual({ auto: true, state: "cloud", here: false, keepInCloud: false });
  expect(sessionPlace(held)).toEqual({ kind: "cloud", label: translate("composer.cloud"), branch: undefined });
  // Back on this Mac: placed as any chat of this Mac again.
  const home = sessionEntry({ ...row, autoSession: { auto: true, state: "local", here: true, keepInCloud: false } });
  expect(sessionPlace(home)).toBeUndefined();
  // A chat started elsewhere that this Mac lists by its machine keeps that machine's name.
  const elsewhere = sessionEntry({
    ...row,
    host: "gpu-box",
    hostKind: "cloud",
    autoSession: { auto: true, state: "cloud", here: false, keepInCloud: false },
  });
  expect(sessionPlace(elsewhere)?.label).toBe("gpu-box");
});
