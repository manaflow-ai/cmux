import { describe, expect, test } from "bun:test";
import { managedAcquireFailure } from "../src/acquirePolicy";

describe("acquire policy", () => {
  test("applies managed balance and model checks to reused credentials too", () => {
    expect(
      managedAcquireFailure({
        credentialClass: "managed",
        model: "gpt-5-mini",
        balanceMicros: 0,
        unflushedEstimateMicros: 0,
      }),
    ).toEqual({ ok: false, error: "insufficient_credits" });

    expect(
      managedAcquireFailure({
        credentialClass: "managed",
        model: "unknown-model",
        balanceMicros: 100,
        unflushedEstimateMicros: 0,
      }),
    ).toEqual({ ok: false, error: "model_not_priced" });

    expect(
      managedAcquireFailure({
        credentialClass: "byok",
        model: "unknown-model",
        balanceMicros: 0,
        unflushedEstimateMicros: 0,
      }),
    ).toBeNull();
  });
});
