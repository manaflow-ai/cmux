// l10n-allow-file: test fixtures.
// Fork Conversation from the app (the palette's step, the chat's right-click menu, its shortcut)
// asks the page to fork (`chat.forkTo`). A chat that cannot fork now must say why instead of doing
// nothing: the fork matrix found an empty Claude chat forking into a chat that failed at its first
// prompt, and a busy chat's palette fork silently doing nothing.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { forkRefusal, forkToTarget } from "./messageMenu";

const snapshot = (over: Partial<AcpmuxSnapshot>): AcpmuxSnapshot =>
  ({ canFork: true, isWorking: false, connection: "connected", rows: [], ...over }) as unknown as AcpmuxSnapshot;

const turn = { kind: "turnSummary", seq: 7 };

test("a chat with a finished turn forks", () => {
  expect(forkRefusal(snapshot({ rows: [turn] as AcpmuxSnapshot["rows"] }))).toBeUndefined();
});

test("a chat with no finished turn has nothing to fork yet", () => {
  expect(forkRefusal(snapshot({}))).toBe("nothingYet");
});

// The person forks a working chat now (2026-10-21): never "fork it when the turn ends".
test("a working chat forks now, as it is", () => {
  const working = snapshot({ isWorking: true, rows: [turn] as AcpmuxSnapshot["rows"] });
  expect(forkRefusal(working)).toBeUndefined();
  expect(forkToTarget(working)).toEqual({ live: true });
});

test("a chat working its first turn forks now too", () => {
  const working = snapshot({ isWorking: true });
  expect(forkRefusal(working)).toBeUndefined();
  expect(forkToTarget(working)).toEqual({ live: true });
});

test("an idle chat forks through its latest finished turn", () => {
  expect(forkToTarget(snapshot({ rows: [turn] as AcpmuxSnapshot["rows"] }))).toEqual({ throughSeq: 7 });
});

test("a chat acpmux cannot fork here says so", () => {
  expect(forkRefusal(snapshot({ canFork: false, rows: [turn] as AcpmuxSnapshot["rows"] }))).toBe("unavailable");
  expect(forkRefusal(snapshot({ connection: "disconnected", rows: [turn] as AcpmuxSnapshot["rows"] }))).toBe(
    "unavailable",
  );
});
