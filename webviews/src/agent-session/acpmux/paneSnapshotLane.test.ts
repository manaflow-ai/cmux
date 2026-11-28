// PendingPaneDraw: a record that would draw the pane while a draw is pending waits for its commit.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { PendingPaneDraw } from "./paneSnapshotLane";

const snap = (id: string): AcpmuxSnapshot =>
  ({ rows: [{ id, kind: "assistant", text: id }] }) as unknown as AcpmuxSnapshot;

test("the newest owed record runs once, when the pending draw commits", () => {
  const pending = new PendingPaneDraw();
  const first = snap("a");
  pending.drew(first, false);
  const ran: string[] = [];
  pending.owe(() => ran.push("older"));
  pending.owe(() => ran.push("newest"));
  pending.committed(snap("other"));
  expect(ran).toEqual([]);
  expect(pending.pending).toBe(true);
  pending.committed(first);
  expect(ran).toEqual(["newest"]);
  expect(pending.pending).toBe(false);
  pending.committed(first);
  expect(ran).toEqual(["newest"]);
});

test("an urgent draw or the pane stopping drops what was owed", () => {
  const pending = new PendingPaneDraw();
  const first = snap("a");
  const ran: string[] = [];
  pending.drew(first, false);
  pending.owe(() => ran.push("owed"));
  pending.drew(snap("b"), true);
  pending.committed(first);
  expect(ran).toEqual([]);
  pending.drew(first, false);
  pending.owe(() => ran.push("owed"));
  pending.forget();
  pending.committed(first);
  expect(ran).toEqual([]);
});
