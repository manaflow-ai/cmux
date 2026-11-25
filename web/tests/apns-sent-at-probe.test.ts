import { describe, expect, it } from "vitest";
import { APNS_MAX_PAYLOAD_BYTES, stampSentAt } from "../services/apns/sender";

// Push-latency probe (optimum-ledger row 16): APNS_SENT_AT_PROBE=1 adds `cmuxSentAtMs` beside `aps`.
describe("push-latency probe: cmuxSentAtMs", () => {
  const payload = { aps: { alert: { title: "t" } }, cmux: { eventId: "e" } };

  it("changes nothing unless enabled", () => {
    expect(stampSentAt(payload, 1_800_000_000_123, false)).toBe(payload);
  });

  it("adds the send time beside aps", () => {
    expect(stampSentAt(payload, 1_800_000_000_123, true)).toEqual({ ...payload, cmuxSentAtMs: 1_800_000_000_123 });
  });

  it("leaves a payload that would pass the APNs limit alone", () => {
    const full = { aps: { alert: { body: "x".repeat(APNS_MAX_PAYLOAD_BYTES - 60) } } };
    expect(Buffer.byteLength(JSON.stringify(full))).toBeLessThanOrEqual(APNS_MAX_PAYLOAD_BYTES);
    expect(stampSentAt(full, 1_800_000_000_123, true)).toBe(full);
  });
});
