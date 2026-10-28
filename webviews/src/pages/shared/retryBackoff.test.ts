// A reconnect backoff doubles to its cap and rests while the page is hidden (MQ4b):
// hidden for a minute it tries nothing; the show tries once, at once.
import { describe, expect, test } from "bun:test";
import { FakeLifecycleDocument, FakePollClock } from "../../../test/support/pagePollFakes";
import { PageLifecycle } from "./pageLifecycle";
import { RetryBackoff } from "./retryBackoff";

function setup(jitter?: () => number) {
  const doc = new FakeLifecycleDocument();
  const clock = new FakePollClock();
  const backoff = new RetryBackoff({
    lifecycle: new PageLifecycle(doc),
    timers: clock,
    firstMs: 250,
    maxMs: 2000,
    jitter,
  });
  const tries: number[] = [];
  // Each try fails and schedules the next, as a reconnect does.
  const attempt = () => {
    tries.push(clock.now);
    backoff.schedule(attempt);
  };
  return { doc, clock, backoff, tries, attempt };
}

describe("RetryBackoff", () => {
  test("waits double up to the cap; a reset starts again", async () => {
    const { clock, backoff, tries, attempt } = setup();
    backoff.schedule(attempt);
    await clock.advance(250 + 500 + 1000 + 2000 + 2000);
    expect(tries).toEqual([250, 750, 1750, 3750, 5750]);
    backoff.reset();
    expect(backoff.nextMs).toBe(250);
  });

  test("a lower cap for one schedule holds the wait after it", async () => {
    const { clock, backoff, tries } = setup();
    const again = () => {
      tries.push(clock.now);
      backoff.schedule(again, 500);
    };
    backoff.schedule(again, 500);
    await clock.advance(250 + 500 + 500);
    expect(tries).toEqual([250, 750, 1250]);
  });

  test("hidden for a minute it tries nothing and arms no timer; the show tries once, at once", async () => {
    const { doc, clock, backoff, tries, attempt } = setup();
    backoff.schedule(attempt);
    doc.hide();
    await clock.advance(60_000);
    expect(tries).toEqual([]);
    expect(clock.armed).toBe(0);
    doc.show();
    expect(tries).toEqual([60_000]);
    expect(backoff.waiting).toBe(true);
  });

  test("the jitter scales each wait", async () => {
    const { clock, backoff, tries, attempt } = setup(() => 0.5);
    backoff.schedule(attempt);
    await clock.advance(125 + 250);
    expect(tries).toEqual([125, 375]);
  });

  test("schedule replaces a waiting retry; cancel drops it", async () => {
    const { clock, backoff, tries } = setup();
    backoff.schedule(() => tries.push(1));
    backoff.schedule(() => tries.push(2));
    expect(clock.armed).toBe(1);
    await clock.advance(10_000);
    expect(tries).toEqual([2]);
    backoff.schedule(() => tries.push(3));
    backoff.cancel();
    expect(backoff.waiting).toBe(false);
    await clock.advance(10_000);
    expect(tries).toEqual([2]);
  });
});
