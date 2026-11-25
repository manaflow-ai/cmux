import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../agent-session/acpmux/model";
import { ChiefTranscript } from "./transcript";

const history = (count: number): readonly AcpmuxRow[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `committed-${index}`,
    version: 1,
    at: index,
    kind: index % 2 ? "assistant" : "user",
    text: `Message ${index}`,
  }));
const live = (id: string, text: string, version = 1): AcpmuxRow => ({
  id,
  version,
  at: 10_000,
  kind: "assistant",
  text,
  streaming: true,
});

test("repeated tokens beside thousands of committed rows preserve the topology snapshot identity", () => {
  const transcript = new ChiefTranscript();
  const committed = history(5_000);
  let topologyChanges = 0;
  const unsubscribe = transcript.subscribe(() => topologyChanges++);
  transcript.update(committed, [live("reply", "")]);
  const snapshot = transcript.snapshot();
  const rows = snapshot.rows;
  expect(snapshot.working).toBe(true);
  expect(topologyChanges).toBe(1);
  for (let token = 1; token <= 200; token++) {
    transcript.update(committed, [live("reply", `Reply token ${token}`, token + 1)]);
    expect(transcript.snapshot()).toBe(snapshot);
    expect(transcript.snapshot().rows).toBe(rows);
  }
  expect(topologyChanges).toBe(1);
  expect(rows).toHaveLength(5_001);
  expect(rows[0]).toBe(committed[0]);
  expect(rows[4_999]).toBe(committed[4_999]);
  expect(transcript.row("reply")?.text).toBe("Reply token 200");
  unsubscribe();
});

test("a mounted reply observes the latest token without notifying another unchanged reply", () => {
  const transcript = new ChiefTranscript();
  const committed = history(3_000);
  const unchanged = live("other-reply", "Other Chief response");
  transcript.update(committed, [live("reply", "First"), unchanged]);
  const observed: Array<string | undefined> = [];
  let otherChanges = 0;
  const unsubscribe = transcript.subscribeRow("reply", () => observed.push(transcript.row("reply")?.text));
  const unsubscribeOther = transcript.subscribeRow("other-reply", () => otherChanges++);
  transcript.update(committed, [live("reply", "First second", 2), unchanged]);
  transcript.update(committed, [live("reply", "First second third", 3), unchanged]);
  expect(observed).toEqual(["First second", "First second third"]);
  expect(otherChanges).toBe(0);
  unsubscribe();
  unsubscribeOther();
  transcript.update(committed, [live("reply", "After unmount", 4), unchanged]);
  expect(observed).toEqual(["First second", "First second third"]);
  expect(otherChanges).toBe(0);
});

test("committing a reply structurally replaces its live row and preserves the committed history", () => {
  const transcript = new ChiefTranscript();
  const committed = history(4_000);
  transcript.update(committed, [live("live-reply", "Your page is ready")]);
  const before = transcript.snapshot();
  let topologyChanges = 0;
  let removedLive: AcpmuxRow | undefined = live("placeholder", "placeholder");
  const unsubscribe = transcript.subscribe(() => topologyChanges++);
  const unsubscribeRow = transcript.subscribeRow("live-reply", () => {
    removedLive = transcript.row("live-reply");
  });
  const persisted: AcpmuxRow = {
    id: "committed-reply",
    version: 1,
    at: 10_000,
    kind: "assistant",
    text: "Your page is ready",
  };
  transcript.update([...committed, persisted], []);
  const after = transcript.snapshot();
  expect(after).not.toBe(before);
  expect(topologyChanges).toBe(1);
  expect(after.working).toBe(false);
  expect(after.rows).toHaveLength(4_001);
  expect(after.rows.at(-1)).toBe(persisted);
  expect(after.rows.some((row) => row.id === "live-reply")).toBe(false);
  expect(after.rows.slice(0, committed.length)).toEqual([...committed]);
  expect(after.rows[0]).toBe(committed[0]);
  expect(after.rows[3_999]).toBe(committed[3_999]);
  expect(removedLive).toBeUndefined();
  unsubscribe();
  unsubscribeRow();
});

test("finishing the same live reply updates the structural working state once", () => {
  const transcript = new ChiefTranscript();
  const committed = history(2_000);
  const running = live("reply", "Finished reply");
  transcript.update(committed, [running]);
  const before = transcript.snapshot();
  let changes = 0;
  const unsubscribe = transcript.subscribe(() => changes++);
  const finished = { ...running, version: 2, streaming: false };
  transcript.update(committed, [finished]);
  expect(transcript.snapshot()).not.toBe(before);
  expect(transcript.snapshot().working).toBe(false);
  expect(transcript.row("reply")).toBe(finished);
  expect(changes).toBe(1);
  transcript.update(committed, [finished]);
  expect(changes).toBe(1);
  unsubscribe();
});
