// A page timeout (a retry backoff, a bounded poll's next round) rests while the page is hidden,
// frozen or parked (MQ4b): no timer is armed, and on show it runs at once ("check")
// or counts its whole period again ("wait").
import { describe, expect, test } from "bun:test";
import { FakeLifecycleDocument, FakePollClock } from "../../../test/support/pagePollFakes";
import { PageLifecycle } from "./pageLifecycle";
import { startPageTimeout } from "./pagePoll";

function setup(options: { hidden?: boolean } = {}) {
  const doc = new FakeLifecycleDocument();
  if (options.hidden) doc.visibilityState = "hidden";
  const lifecycle = new PageLifecycle(doc);
  const clock = new FakePollClock();
  const runs = { count: 0 };
  return { doc, lifecycle, clock, runs, run: () => void (runs.count += 1) };
}

const MINUTE = 60_000;

describe("startPageTimeout", () => {
  test("an active page runs it once, after its time", async () => {
    const { lifecycle, clock, runs, run } = setup();
    startPageTimeout(run, 1000, { lifecycle, timers: clock });
    await clock.advance(999);
    expect(runs.count).toBe(0);
    await clock.advance(MINUTE);
    expect(runs.count).toBe(1);
    expect(clock.armed).toBe(0);
  });

  test("hidden for a minute it arms nothing; the show runs it once", async () => {
    const { doc, lifecycle, clock, runs, run } = setup();
    startPageTimeout(run, 30_000, { lifecycle, timers: clock });
    doc.hide();
    await clock.advance(MINUTE);
    expect(runs.count).toBe(0);
    expect(clock.armed).toBe(0);
    doc.show();
    expect(runs.count).toBe(1);
    doc.hide();
    doc.show();
    await clock.advance(MINUTE);
    expect(runs.count).toBe(1);
  });

  test('"wait" runs nothing on show and counts its whole time again', async () => {
    const { doc, lifecycle, clock, runs, run } = setup();
    startPageTimeout(run, 1500, { lifecycle, timers: clock, onResume: "wait" });
    await clock.advance(1000);
    doc.hide();
    await clock.advance(MINUTE);
    doc.show();
    expect(runs.count).toBe(0);
    await clock.advance(1499);
    expect(runs.count).toBe(0);
    await clock.advance(1);
    expect(runs.count).toBe(1);
  });

  test("started hidden it counts as rested: the show runs it", async () => {
    const { doc, lifecycle, clock, runs, run } = setup({ hidden: true });
    startPageTimeout(run, 1000, { lifecycle, timers: clock });
    await clock.advance(MINUTE);
    expect(clock.started).toBe(0);
    doc.show();
    expect(runs.count).toBe(1);
  });

  test("frozen, it rests through resume until the page is visible", async () => {
    const { doc, lifecycle, clock, runs, run } = setup();
    startPageTimeout(run, 1000, { lifecycle, timers: clock });
    doc.freeze();
    await clock.advance(MINUTE);
    expect(runs.count).toBe(0);
    doc.resume();
    expect(runs.count).toBe(1);
  });

  // A parked (pooled or preloaded) page is hidden by its engine until native shows its view
  // (pageLifecycle.ts, p13-webui-033: the engine is the one visibility truth).
  test("a parked document, hidden by its engine, arms nothing until it is shown", async () => {
    const { doc, lifecycle, clock, runs, run } = setup({ hidden: true });
    startPageTimeout(run, 1000, { lifecycle, timers: clock, onResume: "wait" });
    await clock.advance(MINUTE);
    expect(clock.started).toBe(0);
    doc.show();
    await clock.advance(1000);
    expect(runs.count).toBe(1);
  });

  test("cancel disarms it and leaves no document listener", async () => {
    const { doc, lifecycle, clock, runs, run } = setup();
    const cancel = startPageTimeout(run, 1000, { lifecycle, timers: clock });
    cancel();
    expect(clock.armed).toBe(0);
    expect(doc.listenerCount()).toBe(0);
    doc.hide();
    doc.show();
    await clock.advance(MINUTE);
    expect(runs.count).toBe(0);
  });
});
