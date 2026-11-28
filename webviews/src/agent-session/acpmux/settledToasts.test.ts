import { expect, test } from "bun:test";
import { session } from "../../gallery/fixtures/acpmux";
import { archiveRow } from "./header/archiveRow";
import { SETTLE_TOAST_GROUP, SETTLE_TOAST_MS, settledToast, settleUndoTarget } from "./settledToasts";

test("a settle toast lasts 5 s with Undo on a chat the pane holds, else Open", () => {
  const entry = session({ sessionId: "a", displayTitle: "Fix the cache", archived: true, settled: "merged" });
  let undone = 0;
  let opened = 0;
  const open = () => opened++;
  const spec = settledToast(entry, { undo: () => undone++, open });
  expect(spec.duration).toBe(SETTLE_TOAST_MS);
  expect(spec.group).toBe(SETTLE_TOAST_GROUP);
  expect(spec.message).toBe("Settled: Fix the cache — PR merged");
  expect(spec.actions?.map((action) => action.label)).toEqual(["Undo"]);
  spec.actions?.[0]?.onSelect?.();
  expect([undone, opened]).toEqual([1, 0]);
  // Outside the pane's scope (or on another computer): never Unarchive, only Open.
  const other = settledToast({ ...entry, peer: "build-box" }, { open });
  expect(other.actions?.map((action) => action.label)).toEqual(["Open"]);
  other.actions?.[0]?.onSelect?.();
  expect([undone, opened]).toEqual([1, 1]);
  expect(other.id).not.toBe(spec.id);
  expect(settledToast(entry, {}).actions).toBeUndefined();
});

test("the chat menu offers Unsettle for a settled chat, Unarchive for a plainly archived one", () => {
  const chat = { sessionId: "a", archived: true, local: true };
  expect(archiveRow({ ...chat, settled: true }, () => undefined)?.label).toBe("Unsettle");
  expect(archiveRow(chat, () => undefined)?.label).toBe("Unarchive");
  expect(archiveRow({ ...chat, archived: false, settled: false }, () => undefined)?.label).toBe("Archive");
});

test("Cmd+Z presses the newest settle toast still up, only if it has Undo", () => {
  const undo = () => {};
  const older = { id: "older", undo };
  const newer = { id: "newer", undo };
  const opener = { id: "opener" };
  expect(settleUndoTarget([])).toBeUndefined();
  expect(settleUndoTarget([older, newer])).toBe(newer);
  // The newest closed: the one under it is pressed next.
  expect(settleUndoTarget([older])).toBe(older);
  // A newer toast with Open covers the older Undo: nothing is pressed.
  expect(settleUndoTarget([older, opener])).toBeUndefined();
});
