// l10n-allow-file: browser test fixture.
// Explicit WAAPI start times must use the same origin as the deterministic frame clock.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("frame-clock-native-origin-browser.test.ts", async () => {
  let server: ReturnType<typeof Bun.serve>;
  beforeAll(async () => {
    const built = await Bun.build({
      entrypoints: [path.resolve(import.meta.dir, "browser/frameClock.ts")],
      format: "iife",
      target: "browser",
    });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    const script = await built.outputs[0]!.text();
    server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: () =>
        new Response(
          `<!doctype html><html><head><script>${script.replaceAll("</script", "<\\/script")}</script><script>
      const nativeTime = () => Object.getOwnPropertyDescriptor(AnimationTimeline.prototype, "currentTime").get.call(document.timeline);
      window.clockAtInstall = { native: nativeTime(), synthetic: document.timeline.currentTime, performance: performance.now() };
      window.startupTimers = [];
      for (const [name, delay] of [["later", 50], ["earlier", 20], ["same-due", 50]])
        setTimeout(() => window.startupTimers.push({ name, elapsed: performance.now() - window.firstFrame }), delay);
      requestAnimationFrame(time => {
        window.firstFrame = time;
        window.startupAtFirstFrame = window.startupTimers.slice();
      });
    </script></head><body><div id="row">row</div></body></html>`,
          { headers: { "content-type": "text/html" } },
        ),
    });
  });
  afterAll(async () => {
    await server?.stop(true);
  });
  test("native animation time and synthetic frame time share an origin without changing timer order", async () => {
    const frames = await open120Hz(`http://127.0.0.1:${server.port}/?clock=frames`, { clock: "frames" });
    try {
      const result = await frames.page.evaluate(async () => {
        const native = () =>
          Object.getOwnPropertyDescriptor(AnimationTimeline.prototype, "currentTime")!.get!.call(
            document.timeline,
          ) as number;
        const ticks: { synthetic: number; native: number; elapsed: number }[] = [];
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        const timers: { name: string; elapsed: number }[] = [];
        const timerStart = performance.now();
        for (const [name, delay] of [
          ["first", 5],
          ["earlier", 1],
          ["same-due", 5],
        ] as const)
          setTimeout(() => timers.push({ name, elapsed: performance.now() - timerStart }), delay);
        const animation = document
          .getElementById("row")!
          .animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, fill: "both" });
        const began = Number(document.timeline.currentTime);
        animation.startTime = began;
        for (let i = 0; i < 12; i++) {
          await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
          ticks.push({
            synthetic: Number(document.timeline.currentTime),
            native: native(),
            elapsed: Number(animation.currentTime),
          });
        }
        const fixture = window as unknown as {
          clockAtInstall: { native: number; synthetic: number; performance: number };
          startupTimers: { name: string; elapsed: number }[];
          startupAtFirstFrame: { name: string; elapsed: number }[];
        };
        return {
          began,
          ticks,
          install: fixture.clockAtInstall,
          timers,
          startup: fixture.startupTimers,
          startupAtFirstFrame: fixture.startupAtFirstFrame,
        };
      });
      const drift = Math.max(...result.ticks.map((tick) => Math.abs(tick.synthetic - tick.native)));
      console.log(
        `frame-clock native origin ${JSON.stringify({ install: result.install, drift, timers: result.timers })}`,
      );
      expect(result.install.synthetic).toBe(result.install.native);
      expect(result.install.performance).toBe(result.install.native);
      expect(drift).toBeLessThan(0.15);
      for (let i = 0; i < result.ticks.length; i++) {
        const tick = result.ticks[i]!;
        expect(tick.synthetic - result.began).toBeCloseTo(((i + 1) * 1000) / 120, 6);
        expect(Math.abs(tick.elapsed - (tick.synthetic - result.began))).toBeLessThan(0.15);
      }
      expect(result.timers.map((timer) => timer.name)).toEqual(["earlier", "first", "same-due"]);
      expect(result.timers.map((timer) => timer.elapsed)).toEqual([1, 5, 5]);
      expect(result.startupAtFirstFrame).toEqual([]);
      expect(result.startup.map((timer) => timer.name)).toEqual(["earlier", "later", "same-due"]);
      for (const [index, delay] of [20, 50, 50].entries())
        expect(result.startup[index].elapsed).toBeCloseTo(delay - 1000 / 120, 6);
    } finally {
      await frames.close();
    }
  }, 60_000);
});
