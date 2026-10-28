import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { noChat as emptySnapshot } from "../../gallery/fixtures/acpmux";
import { snapshotFrames } from "./snapshotFrames";

function rig() {
  const frames: (() => void)[] = [];
  const shown: AcpmuxSnapshot[] = [];
  let current = emptySnapshot();
  const presenter = snapshotFrames(
    (run) => frames.push(run),
    (update) => {
      current = update(current);
      shown.push(current);
    },
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

test("a snapshot already delivered in a client frame presents without another frame", () => {
  const { presenter, shown, frames } = rig();
  const next = { ...emptySnapshot(), sessionId: "streaming" };
  presenter.push(next, "frame");
  expect(shown).toEqual([next]);
  expect(frames).toHaveLength(0);
});

test("an already-framed snapshot drains pending snapshots without letting an old callback drain a later burst", () => {
  const { presenter, shown, frames, paint } = rig();
  const first = {
    ...emptySnapshot(),
    sessionId: "chat",
    canHandoff: true,
    handoff: { ready: true, record: { id: "new" } },
  } as unknown as AcpmuxSnapshot;
  const streamed = { ...first, handoff: { ready: false } } as AcpmuxSnapshot;
  presenter.push(first);
  presenter.push(streamed, "frame");
  expect(shown).toHaveLength(1);
  expect(shown[0]!.handoff?.record).toEqual(first.handoff!.record);
  const next = { ...emptySnapshot(), sessionId: "next" };
  const old = frames[0]!;
  presenter.push(next);
  expect(frames).toHaveLength(2);
  old();
  old();
  expect(shown).toHaveLength(1);
  paint();
  expect(shown).toHaveLength(1);
  paint();
  expect(shown).toHaveLength(2);
  expect(shown[1]).toEqual(next);
});

test("stop after an already-framed flush blocks marked deliveries and queued callbacks", () => {
  const { presenter, shown, frames } = rig();
  presenter.push(emptySnapshot());
  presenter.push({ ...emptySnapshot(), sessionId: "flushed" }, "frame");
  expect(shown).toHaveLength(1);
  presenter.push({ ...emptySnapshot(), sessionId: "pending" });
  presenter.stop();
  presenter.push({ ...emptySnapshot(), sessionId: "stopped" }, "frame");
  for (const callback of frames) callback();
  expect(shown).toHaveLength(1);
  expect(shown[0]!.sessionId).toBe("flushed");
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
  const publish = (update: (current: AcpmuxSnapshot) => AcpmuxSnapshot) => {
    shown = update(shown);
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
      (update) => {
        shown = update(shown);
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

for (const timing of [undefined, "frame"] as const) {
  test(`${timing ?? "scheduled"}: the frame reducer preserves the latest ready handoff record`, () => {
    const frames: (() => void)[] = [];
    let shown = {
      ...emptySnapshot(),
      sessionId: "chat",
      canHandoff: true,
      handoff: { ready: true, record: { id: "committed-A" } },
    } as unknown as AcpmuxSnapshot;
    const presenter = snapshotFrames(
      (run) => frames.push(run),
      (update) => {
        shown = update(shown);
      },
    );
    const newer = {
      ...shown,
      handoff: { ready: true, record: { id: "newer-B" } },
    } as unknown as AcpmuxSnapshot;
    presenter.push(newer);
    presenter.push({ ...shown, handoff: { ready: false } } as AcpmuxSnapshot, timing);
    frames.shift()?.();
    expect(shown.handoff?.record).toBe(newer.handoff!.record);
  });

  test(`${timing ?? "scheduled"}: an explicit handoff clear remains cleared through a same-frame partial snapshot`, () => {
    const frames: (() => void)[] = [];
    let shown = {
      ...emptySnapshot(),
      sessionId: "chat",
      canHandoff: true,
      handoff: { ready: true, record: { id: "committed-A" } },
    } as unknown as AcpmuxSnapshot;
    const presenter = snapshotFrames(
      (run) => frames.push(run),
      (update) => {
        shown = update(shown);
      },
    );
    presenter.push({ ...shown, handoff: { ready: true } });
    presenter.push({ ...shown, handoff: { ready: false } }, timing);
    frames.shift()?.();
    expect(shown.handoff?.record).toBeUndefined();
  });

  test(`${timing ?? "scheduled"}: a handoff record cannot cross a same-frame session change and return`, () => {
    const frames: (() => void)[] = [];
    let shown = {
      ...emptySnapshot(),
      sessionId: "chat-A",
      canHandoff: true,
      handoff: { ready: true, record: { id: "committed-A" } },
    } as unknown as AcpmuxSnapshot;
    const presenter = snapshotFrames(
      (run) => frames.push(run),
      (update) => {
        shown = update(shown);
      },
    );
    presenter.push({ ...emptySnapshot(), sessionId: "chat-B", canHandoff: true });
    presenter.push({ ...emptySnapshot(), sessionId: "chat-A", canHandoff: true }, timing);
    frames.shift()?.();
    expect(shown.sessionId).toBe("chat-A");
    expect(shown.handoff?.record).toBeUndefined();
  });
}

test("a frame folds against the state current when React applies its updater", () => {
  const frames: (() => void)[] = [];
  const updates: ((current: AcpmuxSnapshot) => AcpmuxSnapshot)[] = [];
  const presenter = snapshotFrames(
    (run) => frames.push(run),
    (update) => updates.push(update),
  );
  presenter.push({
    ...emptySnapshot(),
    sessionId: "chat",
    canHandoff: true,
    handoff: { ready: false },
  });
  frames.shift()?.();
  const committedAfterScheduling = {
    ...emptySnapshot(),
    sessionId: "chat",
    canHandoff: true,
    handoff: { ready: true, record: { id: "committed-after-scheduling" } },
  } as unknown as AcpmuxSnapshot;
  const shown = updates[0]!(committedAfterScheduling);
  expect(shown.handoff?.record).toBe(committedAfterScheduling.handoff!.record);
});
