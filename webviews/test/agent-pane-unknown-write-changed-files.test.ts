// l10n-allow-file: test fixture paths and file text, not shipped UI.
// The `debug.agent_pane` state's `changedFiles` lists every file the chat's edits changed, as the
// edited-files card does: one with counts, and one listed without (a Write whose old contents are
// unknown). Not a file only a failed call named, or one an edit still waiting for its permission
// names: neither changed anything.
//
// Before: a Write whose old contents are unknown was left out, so a scripted check saw the turn
// change one file of two.
import { expect, test } from "bun:test";
import type { AutomationHost } from "../src/agent-session/acpmux/automation";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { CARGO, NOTES, PLAN, activity, editWithDiff, toolCall, translatorWrite } from "./support/unknownWrite";

async function changedFiles(rows: AcpmuxRow[]) {
  const { automationState } = await import("../src/agent-session/acpmux/automation");
  const snapshot = { type: "snapshot", rows, queue: [], sessions: [], connection: "connected", isWorking: false };
  const host: AutomationHost = {
    snapshot: () => snapshot as unknown as AcpmuxSnapshot,
    call: async () => undefined,
    selectSession: () => {},
    openDiff: () => {},
    diff: () => ({ open: false, paths: [] }),
  };
  return automationState(host).changedFiles;
}

test("changedFiles lists a Write of unknown old contents, without a failed one", async () => {
  const rows = [
    activity("turn-1", [
      await editWithDiff("edit-1", CARGO, 'version = "1.2.0"\n', 'version = "1.3.0"\n'),
      await translatorWrite("write-1", NOTES, "updated"),
      await translatorWrite("write-2", PLAN, "failed"),
    ]),
  ];
  expect(await changedFiles(rows)).toEqual([CARGO, NOTES]);
});

test("a file one call diffed and another named without a diff lists once", async () => {
  const rows = [
    activity("turn-2", [
      await editWithDiff("edit-2", CARGO, "a\n", "b\n"),
      // An edit whose call carried no diff, only its location.
      await toolCall("move-1", [{ title: "Move", kind: "edit", status: "completed", locations: [{ path: CARGO }] }]),
    ]),
    activity("turn-3", [await translatorWrite("write-3", NOTES, "updated")]),
    activity("turn-4", [await translatorWrite("write-4", NOTES, "updated")]),
  ];
  expect(await changedFiles(rows)).toEqual([CARGO, NOTES]);
});

test("an edit with no diff still waiting for its permission is not a changed file", async () => {
  const rows = [
    activity("turn-5", [
      await editWithDiff("edit-3", CARGO, "a\n", "b\n"),
      await toolCall("move-2", [{ title: "Move", kind: "edit", status: "pending", locations: [{ path: PLAN }] }]),
    ]),
  ];
  expect(await changedFiles(rows)).toEqual([CARGO]);
});
