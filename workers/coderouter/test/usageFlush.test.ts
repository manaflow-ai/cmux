import { describe, expect, test } from "bun:test";
import { buildUsageIngest, subtractFlushedEstimateMicros } from "../src/usageFlush";

describe("usage flush", () => {
  test("includes pending status updates until a flush succeeds", () => {
    const { body } = buildUsageIngest(
      "team:openai",
      [],
      [{ credential_id: "cred-1", status: "needs_reauth" }],
    );
    expect(body).toEqual({
      poolId: "team:openai",
      events: [],
      statusUpdates: [{ credentialId: "cred-1", status: "needs_reauth" }],
    });
  });

  test("subtracts only the flushed managed estimate total", () => {
    const { flushedEstimateMicros } = buildUsageIngest(
      "team:openai",
      [
        {
          event_id: "event-1",
          key_id: "kid",
          credential_id: "cred-1",
          family: "openai",
          endpoint_class: "openai_api",
          model: "gpt-5-mini",
          credential_class: "managed",
          status: 200,
          input_tokens: 1,
          output_tokens: 1,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          estimated: 0,
          cost_micros: 7,
          latency_ms: 10,
          ts: 1000,
        },
      ],
      [],
    );

    expect(flushedEstimateMicros).toBe(7);
    expect(subtractFlushedEstimateMicros(12, flushedEstimateMicros)).toBe(5);
    expect(subtractFlushedEstimateMicros(3, flushedEstimateMicros)).toBe(0);
  });
});
