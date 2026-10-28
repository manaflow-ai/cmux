import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { noChat as emptySnapshot } from "../../gallery/fixtures/acpmux";
import { snapshotFrames } from "./snapshotFrames";

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
  const latest = {
    ...first,
    connection: "connected",
    rows: [{ id: "user-1", version: 1, kind: "user" as const, text: "Sent" }],
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
