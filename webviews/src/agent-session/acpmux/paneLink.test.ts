// A snapshot's link and why it was emitted are two fields (RFD 0026: `snapshot.connection` splits
// into `link` and `emitReason`). These pin that the split reads every reason the client emits the
// way the old combined string was read, and that the old `connection` field is still sent.
import { expect, test } from "bun:test";
import { emitted, linkUp, PANE_LINKS, paneLinkOf, paneHeader, type AcpmuxSnapshot } from "./model";
import { turnPhase } from "./turnPhase";
import { keptStopStep } from "./stopThroughReconnect";

/// What `linkUp` read off the combined string before the split.
const oldLinkUp = (connection: string) => connection !== "disconnected" && !connection.startsWith("connecting");

/// Every reason direct.ts, App.tsx and snapshotCache.ts emit, and the pages' fixtures.
const REASONS = [
  "connected",
  "disconnected",
  "connecting",
  "connecting: connection refused by the local daemon",
  "failed",
  "fork failed",
  "error: the agent process exited before it answered",
  "session changed",
  "history",
  "selected",
  "peer offline",
  "waiting: daemon",
  "resyncing",
  "resynced",
  "commands",
  "subsession limits",
  "session purged",
  "replay",
  "permission",
  "daemon resumed",
  "attached",
  "offer child",
  "asks",
  "agent_message_chunk",
  "turn_started",
  "debug",
  "gallery",
];

test("every emitted reason keeps its link reading and its old connection text", () => {
  for (const reason of REASONS) {
    const fields = emitted(reason);
    expect(fields.emitReason).toBe(reason);
    expect(fields.connection).toBe(reason);
    expect(PANE_LINKS).toContain(fields.link);
    expect(linkUp(fields)).toBe(oldLinkUp(reason));
  }
  expect(paneLinkOf("disconnected")).toBe("disconnected");
  expect(paneLinkOf("connecting")).toBe("connecting");
  expect(paneLinkOf("connecting: refused")).toBe("connecting");
  expect(paneLinkOf("failed")).toBe("connected");
});

test("a seeded random walk over reasons: link agrees with the old reading on every step", () => {
  let seed = 0x5eed;
  const next = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed;
  };
  const alphabet = "connectigdsf: _-x";
  for (let step = 0; step < 5000; step++) {
    const pick = next() % 3;
    const reason =
      pick === 0
        ? REASONS[next() % REASONS.length]!
        : Array.from({ length: next() % 16 }, () => alphabet[next() % alphabet.length]).join("");
    const fields = emitted(reason);
    expect(linkUp(fields)).toBe(oldLinkUp(reason));
    expect(fields.link === "disconnected").toBe(reason === "disconnected");
    expect(fields.link === "connecting").toBe(reason.startsWith("connecting"));
    // The readers that took the combined string read the same now.
    expect(turnPhase({ ...fields, isWorking: false })).toBe(oldLinkUp(reason) ? "idle" : "offline");
    const kept = { sessionId: "s1", turnPrompt: "p1", awaitsDisconnect: false };
    expect(keptStopStep(kept, { sessionId: "s1", link: fields.link, isWorking: true, turnPrompt: "p1" }).step).toBe(
      oldLinkUp(reason) ? "send" : "keep",
    );
  }
});

test("the header reads a lost link off link and the failure off emitReason", () => {
  const base = { rows: [], catalog: [], summary: undefined } as unknown as AcpmuxSnapshot;
  const t = (key: string) => key;
  expect(paneHeader({ ...base, ...emitted("disconnected") }, t as never).status).toBe("header.disconnected");
  expect(paneHeader({ ...base, ...emitted("failed: refused") }, t as never)).toMatchObject({
    status: "header.failed",
    detail: "refused",
  });
  expect(paneHeader({ ...base, ...emitted("session changed") }, t as never).status).toBe("");
  expect(paneHeader({ ...base, ...emitted("disconnected") }, t as never, { hostRecovering: true }).status).toBe("");
});
