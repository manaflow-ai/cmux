import { describe, expect, test } from "bun:test";
import { AcpmuxRpcError, HANDOFF_OPS, handoffRecord, supportsHandoff } from "./protocol";

const contractV1 = {
  handoffId: "handoff-1",
  handoffKey: "prepare-key-1",
  state: "draft",
  revision: 1,
  source: {
    sessionId: "session-source", harness: "claude", cwd: "/tmp/handoff-fixture", seq: 12,
    coverage: [{ item: "transcript", status: "included", detail: null }],
    enforcement: { policy: "native policy", label: "native_policy", isolation: "unverified", detail: null },
  },
  target: {
    sessionId: "session-target", harness: "codex", cwd: "/tmp/handoff-fixture",
    coverage: [{ item: "transcript", status: "included", detail: null }],
    enforcement: { policy: "native policy", label: "native_policy", isolation: "unverified", detail: null },
  },
  capsule: {
    text: "Continue from the reviewed checkpoint.", maxBytes: 64 * 1024,
    context: { fromSeq: 0, toSeq: 12, truncated: false, bytes: 38, totalBytes: 38 }, checkpoint: null, memoryRefs: [],
  },
  promptId: null, turnId: null, createdAt: "2026-10-02T00:00:00.000Z", updatedAt: "2026-10-02T00:00:00.000Z",
} as const;

describe("acpmux handoff protocol v1", () => {
  test("publishes the five stable operations", () => {
    expect(HANDOFF_OPS).toEqual({
      prepare: "_acpmux/handoff_prepare",
      get: "_acpmux/handoff_get",
      draft: "_acpmux/handoff_draft",
      start: "_acpmux/handoff_start",
      discard: "_acpmux/handoff_discard",
    });
  });

  test("accepts the v1 owner contract and preserves daemon fields", () => {
    const parsed = handoffRecord(contractV1);
    expect(parsed).toMatchObject({ handoffId: "handoff-1", revision: 1, source: { seq: 12 }, promptId: null, turnId: null });
    expect(parsed.capsule.context).toEqual({ fromSeq: 0, toSeq: 12, truncated: false, bytes: 38, totalBytes: 38 });
  });

  test("rejects malformed or unsafe owner data before it can be rendered", () => {
    const cases = [
      { state: "unknown" },
      { revision: 0 },
      { source: { ...contractV1.source, cwd: "/different" } },
      { target: { ...contractV1.target, harness: contractV1.source.harness } },
      { capsule: { ...contractV1.capsule, maxBytes: 1, text: "too large" } },
      { capsule: { ...contractV1.capsule, context: { ...contractV1.capsule.context, bytes: 39 } } },
      { capsule: { ...contractV1.capsule, checkpoint: { ref: "git:x", attestedBy: "daemon", attestedAt: "now" } } },
      { source: { ...contractV1.source, coverage: [{ item: "unknown", status: "included", detail: null }] } },
    ];
    for (const patch of cases) expect(() => handoffRecord({ ...contractV1, ...patch })).toThrow();
  });

  test("requires every operation and parses only the supported initialized shape", () => {
    const initialized = { _meta: { acpmux: { operations: Object.values(HANDOFF_OPS) } } };
    expect(supportsHandoff(initialized)).toBe(true);
    expect(supportsHandoff({ _meta: { acpmux: { operations: Object.values(HANDOFF_OPS).slice(0, -1) } } })).toBe(false);
    expect(supportsHandoff(undefined)).toBe(false);
  });

  test("extracts typed conflict data without trusting malformed recovery records", () => {
    const handoff = new AcpmuxRpcError({ message: "stale", data: { reason: "stale_revision", handoff: contractV1 } });
    expect(handoff.reason).toBe("stale_revision");
    expect(handoff.handoff?.handoffId).toBe("handoff-1");
    const malformed = new AcpmuxRpcError({ message: "stale", data: { reason: "stale_revision", handoff: { nope: true } } });
    expect(malformed.reason).toBe("stale_revision");
    expect(malformed.handoff).toBeUndefined();
  });
});
