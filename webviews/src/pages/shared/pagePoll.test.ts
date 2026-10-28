// A page poll rests while the page is hidden, frozen or parked (MQ4b): it arms no
// timer and runs nothing, and on show it checks once ("check") or waits one period ("wait"). A
// poll's reads never overlap: the next period starts when the last read settles.
import { describe, expect, test } from "bun:test";
import { FakeLifecycleDocument, FakePollClock, flushMicrotasks } from "../../../test/support/pagePollFakes";
import { PageLifecycle } from "./pageLifecycle";
import { type PollTick, startPagePoll } from "./pagePoll";

function setup(options: { hidden?: boolean } = {}) {
  const doc = new FakeLifecycleDocument();
  if (options.hidden) doc.visibilityState = "hidden";
  const lifecycle = new PageLifecycle(doc);
  const clock = new FakePollClock();
  const ticks: PollTick[] = [];
  return { doc, lifecycle, clock, ticks, run: (tick: PollTick) => void ticks.push(tick) };
}

const MINUTE = 60_000;

describe("startPagePoll", () => {
  test("an active page runs at once, then once a period", async () => {
    const { lifecycle, clock, ticks, run } = setup();
    startPagePoll(run, 1000, { lifecycle, timers: clock });
    expect(ticks).toEqual([{ resumed: false }]);
    await clock.advance(3000);
    expect(ticks.length).toBe(4);
    expect(clock.armed).toBe(1);
  });

  test("a hidden page arms no timer and runs nothing for a minute; its show checks once", async () => {
    const { doc, lifecycle, clock, ticks, run } = setup();
    startPagePoll(run, 4000, { lifecycle, timers: clock });
    doc.hide();
    const before = ticks.length;
    await clock.advance(MINUTE);
    expect(ticks.length).toBe(before);
    expect(clock.armed).toBe(0);
    doc.show();
    expect(ticks.slice(before)).toEqual([{ resumed: true }]);
    expect(clock.armed).toBe(1);
  });

  test('"wait" reads nothing on show and runs one period later', async () => {
    const { doc, lifecycle, clock, ticks, run } = setup();
    startPagePoll(run, 1200, { lifecycle, timers: clock, onResume: "wait" });
    doc.hide();
    await clock.advance(MINUTE);
    doc.show();
    expect(ticks.length).toBe(1);
    await clock.advance(1199);
    expect(ticks.length).toBe(1);
    await clock.advance(1);
    expect(ticks).toEqual([{ resumed: false }, { resumed: false }]);
  });

  test("a frozen page stays at rest through resume until it is visible", async () => {
    const { doc, lifecycle, clock, ticks, run } = setup();
    startPagePoll(run, 1000, { lifecycle, timers: clock });
    doc.freeze();
    await clock.advance(MINUTE);
    expect(ticks.length).toBe(1);
    expect(clock.armed).toBe(0);
    doc.resume();
    expect(ticks).toEqual([{ resumed: false }, { resumed: true }]);
  });

  // A parked (pooled or preloaded) page is hidden by its engine until native shows its view
  // (pageLifecycle.ts, p13-webui-033: the engine is the one visibility truth).
  test("a parked document, hidden by its engine, runs nothing until it is shown", async () => {
    const { doc, lifecycle, clock, ticks, run } = setup({ hidden: true });
    startPagePoll(run, 1000, { lifecycle, timers: clock });
    await clock.advance(MINUTE);
    expect(ticks.length).toBe(0);
    expect(clock.started).toBe(0);
    doc.show();
    expect(ticks.length).toBe(1);
  });

  test("a poll that waits a period first, started hidden, arms on show and runs nothing then", async () => {
    const { doc, lifecycle, clock, ticks, run } = setup({ hidden: true });
    startPagePoll(run, 1000, { lifecycle, timers: clock, immediate: false });
    await clock.advance(MINUTE);
    expect(clock.started).toBe(0);
    doc.show();
    expect(ticks.length).toBe(0);
    await clock.advance(1000);
    expect(ticks.length).toBe(1);
  });

  test("reads never overlap: the next period starts when the read settles", async () => {
    const { lifecycle, clock } = setup();
    let finish: (() => void) | undefined;
    let reads = 0;
    startPagePoll(
      () => {
        reads += 1;
        return new Promise<void>((resolve) => (finish = resolve));
      },
      1000,
      { lifecycle, timers: clock },
    );
    await clock.advance(10_000);
    expect(reads).toBe(1);
    expect(clock.armed).toBe(0);
    finish?.();
    await flushMicrotasks();
    expect(clock.armed).toBe(1);
  });

  test("a page hidden while a read is out arms nothing after it; the show checks once", async () => {
    const { doc, lifecycle, clock } = setup();
    let finish: (() => void) | undefined;
    const ticks: PollTick[] = [];
    startPagePoll(
      (tick) => {
        ticks.push(tick);
        return new Promise<void>((resolve) => (finish = resolve));
      },
      1000,
      { lifecycle, timers: clock },
    );
    doc.hide();
    finish?.();
    await flushMicrotasks();
    await clock.advance(MINUTE);
    expect(clock.started).toBe(0);
    doc.show();
    expect(ticks).toEqual([{ resumed: false }, { resumed: true }]);
  });

  test("a rejected read keeps polling; false stops", async () => {
    const { lifecycle } = setup();
    const clock = new FakePollClock(flushMicrotasks);
    let reads = 0;
    startPagePoll(
      () => {
        reads += 1;
        return reads < 3 ? Promise.reject(new Error("host away")) : false;
      },
      1000,
      { lifecycle, timers: clock },
    );
    await flushMicrotasks();
    await clock.advance(MINUTE);
    expect(reads).toBe(3);
    expect(clock.armed).toBe(0);
  });

  test("stop cancels the timer and leaves no document listener", async () => {
    const { doc, lifecycle, clock, ticks, run } = setup();
    const stop = startPagePoll(run, 1000, { lifecycle, timers: clock });
    expect(doc.listenerCount()).toBeGreaterThan(0);
    stop();
    expect(clock.armed).toBe(0);
    expect(doc.listenerCount()).toBe(0);
    await clock.advance(MINUTE);
    doc.hide();
    doc.show();
    expect(ticks.length).toBe(1);
  });
});
