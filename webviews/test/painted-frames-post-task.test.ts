// Causal controls distinguish final render snapshots from delayed live DOM reads.
import { expect, test } from "bun:test";
import { chromium, webkit } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { installRenderedFrames } from "./support/renderedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Sample = { event: string; readTime: number; frame: number; ink: number };

await requireBrowserLane("painted-frames-post-task.test.ts", async () => {
  const modes = [
    "post-task-repaired",
    "persistent",
    "one-frame",
    "later-ro",
    "two-ro",
    "nested-microtask",
    "reparent",
    "second-round",
  ] as const;
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    for (const sampler of ["legacy", "snapshot"] as const) {
      for (const mode of modes) {
        test(`${name}: ${sampler} attribution ${mode}`, async () => {
          const browser = await engine.launch({ headless: true });
          try {
            const page = await browser.newPage();
            await installPaintedFrames(page);
            await installRenderedFrames(page);
            await page.setContent(`<style>
              .row { position:absolute; left:0; width:200px; height:24px; font:20px/24px Arial; }
            </style><div id="upper" class="row" style="top:0">First words</div>
            <div id="lower" class="row" style="top:24px">Next words</div>
            <div id="probe" style="position:absolute;top:100px;width:1px;height:1px"></div>
            <div><div><div><div id="deeper" style="width:1px;height:1px"></div></div></div></div>`);
            const report = await page.evaluate(
              ({ mode, sampler }) =>
                new Promise<{
                  events: Sample[];
                  samples: Sample[];
                  loopErrors: string[];
                }>((resolve) => {
                  const upper = document.getElementById("upper")!;
                  const lower = document.getElementById("lower")!;
                  const probe = document.getElementById("probe")!;
                  const deeper = document.getElementById("deeper")!;
                  const events: Sample[] = [];
                  const samples: Sample[] = [];
                  const observers: ResizeObserver[] = [];
                  const loopErrors: string[] = [];
                  addEventListener("error", (event) => {
                    if (event.message.includes("ResizeObserver")) loopErrors.push(event.message);
                  });
                  let currentFrame = 0;
                  let armed = false;
                  let triggered = false;
                  let primed = mode !== "second-round";
                  const ink = () => {
                    const first = document.createRange();
                    const second = document.createRange();
                    first.selectNodeContents(upper);
                    second.selectNodeContents(lower);
                    const a = first.getBoundingClientRect();
                    const b = second.getBoundingClientRect();
                    return Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
                  };
                  const record = (event: string, frame = currentFrame) => {
                    const entry = { event, readTime: performance.now(), frame, ink: ink() };
                    events.push(entry);
                    return entry;
                  };
                  const observe = (target: Element, callback: () => void) => {
                    const observer = new ResizeObserver(callback);
                    observers.push(observer);
                    observer.observe(target);
                  };
                  const repair = () => {
                    lower.style.top = "24px";
                    armed = false;
                    record("RO-repair");
                  };
                  if (mode === "post-task-repaired")
                    observe(probe, () => {
                      if (armed) repair();
                      else record("RO-clear");
                    });
                  // This RAF queues its mutation task before the sampler's consumer task.
                  requestAnimationFrame(function trigger(frame) {
                    currentFrame = frame;
                    if (!primed) {
                      primed = true;
                      record("RAF-prime");
                      // raf-read: primes then drives the control; pre-render diagnostic reads are never scored as painted samples.
                      requestAnimationFrame(trigger);
                      return;
                    }
                    record("RAF-trigger");
                    triggered = true;
                    if (mode === "post-task-repaired") {
                      const channel = new MessageChannel();
                      channel.port1.onmessage = () => {
                        channel.port1.close();
                        channel.port2.close();
                        lower.style.top = "0px";
                        probe.style.width = "2px";
                        armed = true;
                        record("task-mutation");
                      };
                      channel.port2.postMessage(null);
                    } else {
                      lower.style.top = "0px";
                      probe.style.width = "2px";
                      record("RAF-mutation");
                      if (mode === "one-frame")
                        requestAnimationFrame((nextFrame) => {
                          currentFrame = nextFrame;
                          lower.style.top = "24px";
                          record("RAF-repair");
                        });
                      if (mode === "reparent") deeper.append(probe);
                    }
                  });
                  const consume = (sample: Sample) => {
                    samples.push(sample);
                    events.push({ ...sample, event: "consume", readTime: performance.now() });
                    if (samples.length < 4) return;
                    for (const observer of observers) observer.disconnect();
                    resolve({ events, samples, loopErrors });
                    return false;
                  };
                  const drive = (frame: number) => {
                    currentFrame = frame;
                    record("RAF-sampler");
                  };
                  if (sampler === "legacy") window.cmuxAfterPaint((frame) => consume(record("sample", frame)), drive);
                  else window.cmuxFrameSnapshots((frame) => record("capture", frame), consume, drive);
                  // All these producers are deliberately created AFTER the sentinel observer.
                  if (mode === "later-ro" || mode === "reparent") observe(probe, repair);
                  if (mode === "two-ro") {
                    observe(probe, () => {
                      lower.style.top = "0px";
                      record("RO-first");
                    });
                    observe(probe, repair);
                  }
                  if (mode === "nested-microtask")
                    observe(probe, () => {
                      record("RO-schedules-microtask");
                      queueMicrotask(() => queueMicrotask(repair));
                    });
                  if (mode === "second-round") {
                    // Initial delivery primes the deeper target; next frame only probe changes.
                    observe(probe, () => {
                      if (!triggered) return;
                      record("RO-first-round");
                      deeper.style.width = "2px";
                    });
                    observe(deeper, repair);
                  }
                }),
              { mode, sampler },
            );
            console.log(`PAINT_POST_TASK_CONTROL ${JSON.stringify({ engine: name, sampler, mode, ...report })}`);
            const collisions = report.samples.filter((entry) => entry.ink > 0.5);
            if (mode === "post-task-repaired") {
              const mutation = report.events.findIndex((entry) => entry.event === "task-mutation");
              const repair = report.events.findIndex((entry) => entry.event === "RO-repair");
              expect(mutation).toBeGreaterThan(0);
              expect(repair).toBeGreaterThan(mutation);
            }
            if (mode === "persistent") expect(collisions.length).toBe(4);
            else if ((sampler === "legacy" && mode === "post-task-repaired") || mode === "one-frame")
              expect(collisions.length).toBe(1);
            else expect(collisions).toEqual([]);
            // Legacy controls establish that checkpoint machinery adds no observer loop errors.
            expect(report.loopErrors).toEqual([]);
            if (sampler === "snapshot" && !["post-task-repaired", "persistent", "one-frame"].includes(mode)) {
              // A clear final sample is only evidence if this actually exercised the earlier
              // observer-phase transient and replaced that snapshot within the same frame.
              const transient = report.events.find((entry) => entry.event === "capture" && entry.ink > 0.5);
              expect(transient).toBeDefined();
              const final = report.samples.find((entry) => entry.frame === transient!.frame);
              expect(final!.ink).toBe(0);
              expect(final!.readTime).toBeGreaterThanOrEqual(transient!.readTime);
              expect(report.events.some((entry) => entry.event === "RO-repair")).toBe(true);
            }
            if (mode === "second-round") {
              const mutation = report.events.find((entry) => entry.event === "RAF-mutation")!;
              const prime = report.events.find((entry) => entry.event === "RAF-prime")!;
              expect(mutation.frame).toBeGreaterThan(prime.frame);
              expect(report.events.some((entry) => entry.event === "RO-repair" && entry.frame === prime.frame)).toBe(
                true,
              );
              expect(report.events.some((entry) => entry.event === "RO-repair" && entry.frame === mutation.frame)).toBe(
                true,
              );
              if (sampler === "snapshot")
                expect(
                  report.events.filter(
                    (entry) => entry.event === "capture" && entry.frame === mutation.frame && entry.ink > 0.5,
                  ).length,
                ).toBeGreaterThanOrEqual(2);
            }
            if (mode !== "persistent") expect(report.samples.at(-1)!.ink).toBe(0);
          } finally {
            await browser.close();
          }
        }, 30_000);
      }
    }
  }
});
