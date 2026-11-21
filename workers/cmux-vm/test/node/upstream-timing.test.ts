/**
 * The request's provider tally (src/upstream/timing.ts): a body read after the answer headers is the same call's
 * provider time, so it adds ms but no call (review F1 on manaflow-ai/cmux#47767).
 */
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import { timedUpstream, timedUpstreamBody, UpstreamTime, type UpstreamTally } from "../../src/upstream/timing.ts";

const wait = (ms: number) => Effect.promise(() => new Promise<void>((resolve) => setTimeout(resolve, ms)));

const inRequest = <A>(effect: Effect.Effect<A>) => {
  const tally: UpstreamTally = { ms: 0, calls: 0 };
  return Effect.runPromise(Effect.locally(effect, UpstreamTime, tally)).then(() => tally);
};

describe("upstream timing", () => {
  it("counts a slow body read as the provider's time of the same call", async () => {
    const tally = await inRequest(Effect.zipRight(timedUpstream(wait(5)), timedUpstreamBody(wait(40))));
    expect(tally.calls).toBe(1);
    expect(tally.ms).toBeGreaterThanOrEqual(40);
  });

  it("counts a body read that fails too", async () => {
    const tally = await inRequest(
      Effect.zipRight(timedUpstream(Effect.void), timedUpstreamBody(Effect.zipRight(wait(30), Effect.fail("x")))).pipe(
        Effect.catchAll(() => Effect.void),
      ),
    );
    expect(tally.calls).toBe(1);
    expect(tally.ms).toBeGreaterThanOrEqual(30);
  });

  it("records nothing outside a request", async () => {
    await expect(Effect.runPromise(timedUpstreamBody(Effect.succeed(1)))).resolves.toBe(1);
  });
});
