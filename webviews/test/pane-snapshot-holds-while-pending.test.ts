// One pane transition draw at a time (paneSnapshotLane.ts `PendingPaneDraw`): a new update in React's
// transition lanes restarts the render in progress, so a draw per replayed event threw the whole pane's
// render away whenever one took longer than the gap between events (Leo, 2026-11-26: "Why should non
// visible thing even affect the renderer thread anyways?"). These check the hold without React's renderer:
// the newest held snapshot draws when the pending one commits, an urgent draw drops what was held, and a
// commit of anything (a snapshot set around this lane) releases a held draw, so none waits forever.
import { expect, test } from "bun:test";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { drawPaneSnapshot, PendingPaneDraw } from "../src/agent-session/acpmux/paneSnapshotLane";

function row(id: string, kind: AcpmuxRow["kind"], text = ""): AcpmuxRow {
  return { id, kind, text, version: text.length } as AcpmuxRow;
}

function snap(seq: number, extra: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return {
    sessionId: "s",
    connection: "connected",
    isWorking: true,
    rows: [row("u1", "user", "hi"), row("a1", "agent", "x".repeat(seq))],
    ...extra,
  } as AcpmuxSnapshot;
}

function lane() {
  const pending = new PendingPaneDraw();
  const drawn: AcpmuxSnapshot[] = [];
  let last: AcpmuxSnapshot | undefined;
  const send = (next: AcpmuxSnapshot) => {
    const before = last;
    last = next;
    drawPaneSnapshot(before, next, pending, () => drawn.push(next));
  };
  return { pending, drawn, send };
}

test("snapshots that come while a draw is pending hold, and only the newest draws when it commits", () => {
  const { pending, drawn, send } = lane();
  const first = snap(1);
  send(first); // the first snapshot draws at once
  expect(drawn).toEqual([first]);
  const second = snap(2);
  send(second);
  expect(drawn).toEqual([first, second]);
  expect(pending.pending).toBe(true);
  send(snap(3));
  const fourth = snap(4);
  send(fourth);
  expect(drawn.length, "held while the second is pending").toBe(2);
  pending.committed(second);
  expect(drawn.at(-1), "the newest held draws on the commit").toBe(fourth);
  expect(drawn.length).toBe(3);
  expect(pending.pending).toBe(true);
  pending.committed(fourth);
  expect(pending.pending).toBe(false);
  expect(drawn.length, "nothing more was held").toBe(3);
});

test("an urgent draw goes at once and drops what was held", () => {
  const { pending, drawn, send } = lane();
  send(snap(1));
  const second = snap(2);
  send(second);
  send(snap(3));
  const sent = snap(4, { rows: [...snap(4).rows, row("u2", "user", "next")] });
  send(sent);
  expect(drawn.at(-1)).toBe(sent);
  expect(pending.pending).toBe(false);
  pending.committed(sent);
  expect(drawn.at(-1), "the held one is not drawn over the newer urgent one").toBe(sent);
});

test("a commit of a snapshot set around the lane releases a held draw", () => {
  const { pending, drawn, send } = lane();
  send(snap(1));
  send(snap(2));
  const held = snap(3);
  send(held);
  pending.committed(snap(9)); // the host's snapshot overtook the pending one, whose rows never commit
  expect(drawn.at(-1)).toBe(held);
  pending.committed(held);
  expect(pending.pending).toBe(false);
});
