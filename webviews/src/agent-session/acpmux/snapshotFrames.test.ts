import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { noChat as emptySnapshot } from "../../gallery/fixtures/acpmux";
import { keepHandoff, snapshotFrames } from "./snapshotFrames";

function rig() {
  const frames: (() => void)[] = [];
  const shown: AcpmuxSnapshot[] = [];
  const presenter = snapshotFrames(
    (run) => frames.push(run),
    (next) => shown.push(next),
  );
  return { frames, shown, presenter, paint: () => frames.shift()?.() };
}

test("a daemon burst presents the latest snapshot once in the display frame", () => {
  const { presenter, shown, frames, paint } = rig();
  const first = { ...emptySnapshot(), sessionId: "chat", connection: "attached" };
  const latest: AcpmuxSnapshot = {
    ...first,
    connection: "connected",
    rows: [{ id: "user-1", version: 1, at: 1, kind: "user" as const, text: "Sent" }],
  };
  presenter.push(first);
  presenter.push(latest);
  expect(shown).toHaveLength(0);
  expect(frames).toHaveLength(1);
  paint();
  expect(shown).toEqual([latest]);
});

test("an intermediate handoff record survives a later partial snapshot of the same chat", () => {
  const { presenter, shown, paint } = rig();
  const first = {
    ...emptySnapshot(),
    sessionId: "chat",
    canHandoff: true,
    handoff: { ready: false, record: { id: "record" } },
  } as unknown as AcpmuxSnapshot;
  presenter.push(first);
  presenter.push({ ...first, handoff: { ready: false } } as AcpmuxSnapshot);
  paint();
  expect(shown).toHaveLength(1);
  expect(shown[0]!.handoff?.record).toEqual(first.handoff!.record);
});

test("a handoff record never crosses a session change", () => {
  const { presenter, shown, paint } = rig();
  presenter.push({
    ...emptySnapshot(),
    sessionId: "before",
    canHandoff: true,
    handoff: { record: { id: "old" } },
  } as unknown as AcpmuxSnapshot);
  presenter.push({ ...emptySnapshot(), sessionId: "after", canHandoff: true });
  paint();
  expect(shown).toHaveLength(1);
  expect(shown[0]!.sessionId).toBe("after");
  expect(shown[0]!.handoff?.record).toBeUndefined();
});

test("a stopped connection cannot present its pending snapshot", () => {
  const { presenter, shown, paint } = rig();
  presenter.push(emptySnapshot());
  presenter.stop();
  paint();
  presenter.push(emptySnapshot());
  expect(shown).toHaveLength(0);
});

test("a disconnected client cannot overwrite ready or error state while the replacement connects", () => {
  const frames: (() => void)[] = [];
  let shown = emptySnapshot();
  const schedule = (run: () => void) => frames.push(run);
  const publish = (next: AcpmuxSnapshot) => {
    shown = next;
  };
  const old = snapshotFrames(schedule, publish);
  old.push({ ...emptySnapshot(), sessionId: "old" });
  old.stop();
  shown = { ...emptySnapshot(), connection: "connecting: refused" };
  const replacement = snapshotFrames(schedule, publish);
  replacement.push({ ...emptySnapshot(), sessionId: "new" });
  frames.shift()?.();
  expect(shown.connection).toBe("connecting: refused");
  expect(shown.sessionId).toBeUndefined();
  frames.shift()?.();
  expect(shown.sessionId).toBe("new");
});

test("coalescing keeps the current delivery failure and queued prompt intact", () => {
  const { presenter, shown, paint } = rig();
  presenter.push({ ...emptySnapshot(), sessionId: "chat" });
  const next: AcpmuxSnapshot = {
    ...emptySnapshot(),
    sessionId: "chat",
    rows: [
      {
        id: "user-1",
        version: 2,
        at: 1,
        kind: "user",
        text: "Sent",
        delivery: { state: "failed", promptId: "prompt", sessionId: "chat", sentAt: 1, failedAt: 2, error: "refused" },
      },
    ],
    queue: [{ id: "queued", prompt: "Keep this" }],
  };
  presenter.push(next);
  paint();
  expect(shown[0]!.rows[0]!.delivery?.error).toBe("refused");
  expect(shown[0]!.queue).toEqual(next.queue);
});

test("a retained closed-client callback cannot change bookkeeping or shared stores", () => {
  const frames: (() => void)[] = [];
  const reconciled: string[] = [];
  const sharedSessions: string[] = [];
  let snapshotRef = emptySnapshot();
  let rowsRef = snapshotRef.rows;
  let shown = snapshotRef;
  const connect = () => {
    const presentation = snapshotFrames(
      (run) => frames.push(run),
      (next) => {
        shown = next;
      },
    );
    const receive = presentation.guard((next: AcpmuxSnapshot) => {
      reconciled.push(next.sessionId!);
      rowsRef = next.rows;
      snapshotRef = next;
      sharedSessions.push(next.sessionId!);
      presentation.push(next);
    });
    return { presentation, receive };
  };
  const old = connect();
  old.receive({ ...emptySnapshot(), sessionId: "old" });
  old.presentation.stop();
  const current = connect();
  const latest: AcpmuxSnapshot = {
    ...emptySnapshot(),
    sessionId: "current",
    rows: [{ id: "user-current", version: 1, at: 1, kind: "user", text: "Current" }],
  };
  current.receive(latest);
  // Protocol bookkeeping is synchronous, before either connection's presentation frame.
  expect(snapshotRef.sessionId).toBe("current");
  expect(rowsRef).toBe(latest.rows);
  expect(reconciled).toEqual(["old", "current"]);
  expect(sharedSessions).toEqual(["old", "current"]);
  expect(shown.sessionId).toBeUndefined();
  // Deliberately invoke a retained old callback after the replacement is current.
  old.receive({ ...emptySnapshot(), sessionId: "retained-old" });
  expect(snapshotRef.sessionId).toBe("current");
  expect(rowsRef).toBe(latest.rows);
  expect(reconciled).toEqual(["old", "current"]);
  expect(sharedSessions).toEqual(["old", "current"]);
  frames.shift()?.();
  expect(shown.sessionId).toBeUndefined();
  frames.shift()?.();
  expect(shown).toBe(latest);
});

test("a stopped connection cannot run a second disconnect callback", () => {
  const { presenter } = rig();
  let disconnected = 0;
  const lost = presenter.guard(() => {
    presenter.stop();
    disconnected += 1;
  });
  lost();
  lost();
  expect(disconnected).toBe(1);
});

test("the publish fold keeps the newer handoff record carried by a coalesced snapshot", () => {
  const frames: (() => void)[] = [];
  let shown = {
    ...emptySnapshot(),
    sessionId: "chat",
    canHandoff: true,
    handoff: { ready: true, record: { id: "committed-A" } },
  } as unknown as AcpmuxSnapshot;
  const presenter = snapshotFrames(
    (run) => frames.push(run),
    (next) => {
      shown = keepHandoff(shown, next);
    },
  );
  const newer = {
    ...shown,
    handoff: { ready: true, record: { id: "newer-B" } },
  } as unknown as AcpmuxSnapshot;
  presenter.push(newer);
  presenter.push({ ...shown, handoff: { ready: false } } as AcpmuxSnapshot);
  frames.shift()?.();
  expect(shown.handoff?.record).toBe(newer.handoff!.record);
});
