// cmux-web-test-timeout: 360
// The New Tab page follows a live window resize frame by frame (Leo 2026-10-20: when the window or
// pane resizes, the page relayouts late, jumps and stutters). Dragged from 1100x760 to 480x400 and
// back in two seconds, past the 480px-tall padding step and the 520px container width, the
// composer's card never jumps: per frame its top (on the Default template, which docks it at the
// foot, its distance from the foot) moves at most 0.6px per px of height + 2px, its left edge at
// most 0.6px per px of width + 2px and its width at most 1px per px + 2px. The layout is CSS only:
// the field (where the text is typed) never has an inline height and a one-line draft keeps its
// one-line row. ResizeObserver callbacks take at most 2ms a frame (p95 in Chromium; the mean in
// WebKit, whose clock ticks in whole ms). In Chromium the frames hold 60fps: p95 interval at most
// 20ms, none over 50ms, no long animation frame over 50ms; headless WebKit's rAF cadence is not a
// steady 60Hz, so its intervals are logged only. The first 10 frames are warm-up, and a sweep that
// misses only the timing budgets (a busy host) runs again, up to 3 sweeps, the best counting.
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host and acpmux daemon,
// in an iframe of a same-origin host page whose rAF loop sets the iframe's size every frame and, at
// the next frame (after the iframe laid out, ran its ResizeObservers and painted), records the card,
// the field and the frame's ResizeObserver time.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-live-resize.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One frame: its interval, the page's size, the card's rect, the field's height and inline height
/// and the ResizeObserver time.
type Sample = Record<"dt" | "w" | "h" | "top" | "foot" | "left" | "width" | "field" | "ro", number> & {
  inline: string;
};
/// What the init script keeps on the New Tab page's window.
type Inner = Window & { __ro: number; __shifts: number[]; __loaf: number[] };

await requireBrowserLane("new-tab-live-resize.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new-tab-live-resize: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab live resize", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const ATLAS = `${HOME}/src/atlas`;
  const now = Date.now();
  const sessions = Array.from({ length: 8 }, (_, index) => ({
    sessionId: `s-${index}`,
    cwd: ATLAS,
    harness: index % 2 ? "codex" : "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: now - (index + 1) * 3_600_000,
    title: `Chat number ${index + 1}`,
  }));
  const LIST_DELAY = 600;
  const FROM = [1100, 760] as const;
  const TO = [480, 400] as const;
  const SWEEP_MS = 2_000;
  const WARM_UP = 10;
  const HOST = "/new-tab-live-resize-host.html";

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id === undefined) return;
          let result: unknown = null;
          if (message.method === "initialize")
            result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
          else if (message.method === "_acpmux/watch") {
            await Bun.sleep(LIST_DELAY); // fixed-wait: the stand-in daemon's list latency
            result = { sessions };
          } else if (message.method === "_acpmux/sessions") result = { sessions: [] };
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The host page with the New Tab page (as a new workspace opens one) in its iframe. In the
  /// iframe, a stand-in host bridge, a ResizeObserver that sums its callbacks' time, and in
  /// Chromium the layout shifts and long animation frames.
  async function load(name: string, template: string): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 900 } });
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const context = { kind: "agent", hotkeys: {}, home: HOME, projects: [ATLAS], host: "cosmic-gray", template };
    await page.addInitScript(
      ({ endpoint, context }) => {
        const w = window as unknown as Record<string, unknown>;
        // Long animation frames in both documents: the host page's frame runs the iframe's too.
        const loaf: number[] = [];
        const shifts: number[] = [];
        Object.assign(w, { __shifts: shifts, __loaf: loaf });
        const types = PerformanceObserver.supportedEntryTypes;
        if (types.includes("long-animation-frame"))
          new PerformanceObserver((list) => {
            for (const entry of list.getEntries()) loaf.push(entry.duration);
          }).observe({ type: "long-animation-frame" });
        if (window.top === window) return;
        if (types.includes("layout-shift"))
          new PerformanceObserver((list) => {
            for (const entry of list.getEntries()) shifts.push((entry as unknown as { value: number }).value);
          }).observe({ type: "layout-shift" });
        w.__cmuxNewTabContext = context;
        // fixed-wait: the stand-in host's reply latency.
        const later = (ms: number, value: unknown) =>
          new Promise((resolve) => setTimeout(() => resolve({ ok: true, value }), ms));
        const transport = { protocolVersion: 1, transport: "acpmux-websocket", endpoint, token: "t", newSession: true };
        const replies: Record<string, unknown> = {
          ready: { ...transport, newTab: context, machineName: "cosmic-gray" },
          "newTab.context": { newTab: context },
          "project.list": { projects: context.projects },
          "transport.gesture": { ticket: "gesture" },
        };
        // fixed-wait: the stand-in host answers ready late, as the real one does.
        const answer = ({ method }: { method: string }) => later(method === "ready" ? 100 : 0, replies[method] ?? null);
        w.webkit = { messageHandlers: { agentSession: { postMessage: answer } } };
        w.__ro = 0;
        const Native = window.ResizeObserver;
        window.ResizeObserver = class extends Native {
          constructor(callback: ResizeObserverCallback) {
            super((entries, observer) => {
              const start = performance.now();
              try {
                callback(entries, observer);
              } finally {
                w.__ro = (w.__ro as number) + performance.now() - start;
              }
            });
          }
        };
      },
      { endpoint, context },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    const origin = `http://127.0.0.1:${port}`;
    const frameStyle = `display:block;border:0;width:${FROM[0]}px;height:${FROM[1]}px`;
    await page.route(`${origin}${HOST}`, (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><body style="margin:0"><iframe src="/" style="${frameStyle}"></iframe></body>`,
      }),
    );
    await page.goto(`${origin}${HOST}`);
    return page;
  }

  /// Drags the iframe's size from FROM to TO and back, one size per frame; one sample per frame.
  function sweep(page: Page) {
    return page.evaluate(
      ({ from, to, ms, warmUp }) => {
        const iframe = document.querySelector("iframe")!;
        const inner = iframe.contentWindow as unknown as Inner;
        const outer = window as unknown as Inner;
        const doc = iframe.contentDocument!;
        const samples: Sample[] = [];
        let start: number | undefined;
        let last: number | undefined;
        let done = false;
        return new Promise<{ samples: Sample[]; shifts: number[]; loaf: number[] }>((resolve) => {
          const frame = (time: number) => {
            // What the last frame laid out and painted, read before this frame dirties it.
            const screen = doc.querySelector(".nt-screen")!;
            const s = screen.getBoundingClientRect();
            const box = doc.querySelector(".nt-box")!.getBoundingClientRect();
            const field = doc.querySelector<HTMLElement>(".nt-field")!;
            samples.push({
              dt: last === undefined ? 0 : time - last,
              w: screen.clientWidth,
              h: screen.clientHeight,
              top: box.top - s.top,
              foot: s.bottom - box.bottom,
              left: box.left - s.left,
              width: box.width,
              field: field.getBoundingClientRect().height,
              inline: field.style.height,
              ro: inner.__ro,
            });
            inner.__ro = 0;
            last = time;
            if (samples.length === warmUp) {
              inner.__shifts.length = 0;
              inner.__loaf.length = 0;
              outer.__loaf.length = 0;
            }
            if (done) {
              resolve({ samples, shifts: [...inner.__shifts], loaf: [...outer.__loaf, ...inner.__loaf] });
              return;
            }
            start ??= time;
            const progress = Math.min(1, (time - start) / ms);
            const f = progress < 0.5 ? progress * 2 : 2 - progress * 2;
            iframe.style.width = `${Math.round(from[0] + (to[0] - from[0]) * f)}px`;
            iframe.style.height = `${Math.round(from[1] + (to[1] - from[1]) * f)}px`;
            done = progress >= 1;
            // raf-read: reads what the previous frame laid out and painted, before this frame resizes the iframe.
            requestAnimationFrame(frame);
          };
          requestAnimationFrame(frame);
        });
      },
      { from: FROM, to: TO, ms: SWEEP_MS, warmUp: WARM_UP },
    );
  }

  const percentile = (values: number[], p: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)] ?? 0;
  };
  const px = (value: number) => value.toFixed(1);

  // Cards is what an unset template shows; Default docks the composer at the foot (stage layout);
  // Threads has no padding of its own, so it carries the 480px-tall step of `.nt-screen`.
  for (const template of ["cards", "default", "composer", "threads"]) {
    test.each(engines.map(([name]) => name))(`%s: the ${template} page follows a live resize`, async (name) => {
      const page = await load(name, template);
      const frame = page.frameLocator("iframe");
      await frame.locator(".nt-field").waitFor({ timeout: 30_000 });
      // fixed-wait: the stand-in list arrives after LIST_DELAY and its rows settle before the sweep.
      await page.waitForTimeout(LIST_DELAY + 1_000);
      // Focus, not click: a click waits for two equal frames, which a starved WebKit host may not give.
      // The field is MarkdownField: its editable element inside `.nt-field` takes the keyboard.
      await frame.locator(".nt-field .ProseMirror").focus();
      await page.keyboard.type("fix the build");
      // fixed-wait: the typed draft lays out before the sweep measures its one-line height.
      await page.waitForTimeout(300);
      const stage = (await frame.locator(".nt-screen").getAttribute("data-layout")) === "stage";
      // One line of the field's text plus its insets (the Default template's 52px row).
      // MarkdownField's `.nt-field` wrapper holds the insets and its editable (`.acpmux-md`) the
      // line height, both of which the textarea held.
      const oneLine = await frame.locator(".nt-field").evaluate((node) => {
        const inset = getComputedStyle(node);
        const text = getComputedStyle(node.querySelector(".acpmux-md")!);
        const insets = parseFloat(inset.paddingTop) + parseFloat(inset.paddingBottom);
        if (text.lineHeight.endsWith("px")) return parseFloat(text.lineHeight) + insets;
        return node.getBoundingClientRect().height;
      });
      // The draft is in the field, so the sweep measures a field with text in it.
      expect(
        await frame
          .locator(".nt-field")
          .evaluate((node) =>
            (node as Element & { acpmuxMarkdownField?: { value(): string } }).acpmuxMarkdownField?.value(),
          ),
      ).toBe("fix the build");
      // A page that measures and sets on every frame misses the timing budgets on every sweep.
      let best: { layout: string[]; timing: string[] } | undefined;
      for (let attempt = 1; attempt <= 3 && (best === undefined || best.timing.length > 0); attempt++) {
        const result = check(name, stage, oneLine, await sweep(page), `${name} ${template} #${attempt}`);
        if (result.layout.length) {
          best = result;
          break;
        }
        if (best === undefined || result.timing.length < best.timing.length) best = result;
      }
      await page.close();
      expect([...best!.layout, ...best!.timing]).toEqual([]);
    });
  }

  /// The failures of one sweep: the layout ones and the timing ones; logs its figures.
  function check(
    name: string,
    stage: boolean,
    oneLine: number,
    { samples, shifts, loaf }: { samples: Sample[]; shifts: number[]; loaf: number[] },
    label: string,
  ) {
    const failures: string[] = [];
    for (let i = 1; i < samples.length; i++) {
      const [a, b] = [samples[i - 1]!, samples[i]!];
      const at = `frame ${i} ${a.w}x${a.h} -> ${b.w}x${b.h}`;
      const dh = Math.abs(b.h - a.h);
      const dw = Math.abs(b.w - a.w);
      const moved = stage ? Math.abs(b.foot - a.foot) : Math.abs(b.top - a.top);
      if (moved > 0.6 * dh + 2)
        failures.push(`${at}: the card's ${stage ? "distance from the foot" : "top"} jumped ${px(moved)}px`);
      if (Math.abs(b.left - a.left) > 0.6 * dw + 2)
        failures.push(`${at}: the card's left edge jumped ${px(b.left - a.left)}px`);
      if (Math.abs(b.width - a.width) > dw + 2)
        failures.push(`${at}: the card's width jumped ${px(b.width - a.width)}px`);
    }
    const inline = samples.filter((sample) => sample.inline);
    if (inline.length)
      failures.push(`the field had an inline height in ${inline.length} frames (${inline[0]!.inline})`);
    const tall = samples.filter((sample) => Math.abs(sample.field - oneLine) > 0.5);
    if (tall.length)
      failures.push(`the one-line field left ${px(oneLine)}px in ${tall.length} frames (${px(tall[0]!.field)}px)`);

    const timing: string[] = [];
    const timed = samples.slice(WARM_UP);
    const intervals = timed.map((sample) => sample.dt);
    const p95 = percentile(intervals, 0.95);
    const worst = Math.max(...intervals);
    const longFrames = loaf.filter((duration) => duration > 50);
    if (name === "chromium") {
      // A starved sweep draws a handful of frames: too few to clear the warm-up proves nothing.
      if (timed.length < 60) timing.push(`only ${samples.length} frames in ${SWEEP_MS}ms`);
      if (p95 > 20) timing.push(`p95 frame interval ${px(p95)}ms > 20ms`);
      if (worst > 50) timing.push(`a frame took ${px(worst)}ms > 50ms`);
      if (longFrames.length)
        timing.push(`${longFrames.length} long animation frame(s), longest ${px(Math.max(...longFrames))}ms`);
    }
    const ro = timed.map((sample) => sample.ro);
    const roMean = ro.reduce((sum, value) => sum + value, 0) / Math.max(1, ro.length);
    const roP95 = percentile(ro, 0.95);
    // WebKit's clock ticks in whole milliseconds: its mean is the unbiased figure there.
    const [roStat, roValue] = name === "webkit" ? (["mean", roMean] as const) : (["p95", roP95] as const);
    if (roValue > 2) timing.push(`ResizeObserver callbacks took ${px(roValue)}ms a frame (${roStat}) > 2ms`);

    console.info(
      `${label}: ${samples.length} frames, interval p95 ${px(p95)}ms max ${px(worst)}ms, ` +
        `ResizeObserver p95 ${px(roP95)}ms mean ${roMean.toFixed(2)}ms, long frames ${loaf.length}, ` +
        `layout shift ${shifts.reduce((sum, value) => sum + value, 0).toFixed(3)}, field ${px(oneLine)}px` +
        [...failures.slice(0, 40), ...timing].map((line) => `\n  ${line}`).join(""),
    );
    return { layout: failures, timing };
  }
});
