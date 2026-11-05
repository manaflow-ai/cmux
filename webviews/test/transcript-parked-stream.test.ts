// Leo: streaming while parked near the bottom must not recapture the reader.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { readFileSync } from "node:fs";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
type Sample = {
  token: number;
  caller: string;
  following?: boolean;
  atLatest?: boolean;
  top?: number;
};
type Probe = Window & {
  __token: number;
  __samples: Sample[];
  __probe(caller: string, following?: boolean, atLatest?: boolean): void;
  __showRowsSync(rows: unknown[]): void;
};
await requireBrowserLane("transcript-parked-stream.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
      // Probes stay in this harness; production does no per-token diagnostic work.
      plugins: [
        {
          name: "parked-follow-probes",
          enforce: "pre",
          load(id) {
            if (id.endsWith("/test/browser/transcript-follow.harness.tsx"))
              return readFileSync(id, "utf8")
                .replace("<VirtualTranscript", '<VirtualTranscript jumpButton={location.search.includes("painted")}')
                .replace(
                  "turnView(shown, expanded)",
                  'turnView(shown, expanded, location.search.includes("painted") ? {working, liveRuns: true, lineBelow: true} : {})',
                );
            if (!id.endsWith("/src/agent-session/acpmux/App.tsx")) return;
            let source = readFileSync(process.env.CMUX_PARKED_SOURCE ?? id, "utf8");
            const inserts = [
              [
                "const top = scrollAnchorBase(live, scrolledTo.current.top, readerLeft);",
                'globalThis.__geometry?.("anchor-base", {live, stored: scrolledTo.current.top, top, readerLeft});',
              ],
              [
                "anchorTop: logicalTop,\n        });",
                'globalThis.__geometry?.("anchor-correction", {top, logicalTop, nextTop, live: node.scrollTop});',
              ],
              ["followingRef.current = next;", 'globalThis.__probe?.("follow", next);'],
              [
                "followingRef.current = atLatest;",
                'globalThis.__probe?.("queueScroll", atLatest, atLatest); globalThis.__geometry?.("queueScroll", {top, atLatest});',
              ],
              [
                "if (didOpenAtLatest.current && atLatest) {",
                'globalThis.__probe?.("layout-follow", followingRef.current, atLatest);',
              ],
              [
                "} else if (top > 0 || rows[0]?.id !== oldRows[0]?.id) {",
                'globalThis.__probe?.("layout-anchor", followingRef.current, atLatest);',
              ],
              [
                "if (layoutDriven) {",
                'globalThis.__probe?.("scroll-layout", followingRef.current, scrolledTo.current.atLatest);',
              ],
              [
                "followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);",
                'globalThis.__probe?.("snapshot", followingRef.current, scrolledTo.current.atLatest);',
              ],
            ];
            for (const [needle, probe] of inserts) {
              if (!source.includes(needle)) throw new Error(`Missing probe site: ${needle}`);
              source = source.replaceAll(needle, `${needle}\n${probe}`);
            }
            source = source.replace(
              "if (acpmuxPerf.enabled && renderStart > 0) {",
              'globalThis.__probe?.("commit", followingRef.current, scrolledTo.current.atLatest); if (acpmuxPerf.enabled && renderStart > 0) {',
            );
            return source;
          },
        },
      ],
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test("parked readers stay released after the input window expires; pinned readers follow", async () => {
    const results: {
      distance: number;
      flips: number;
      writes: number;
      moved: number;
      gap: number;
      following: boolean | undefined;
    }[] = [];
    for (const distance of [3, 10, 20, 40, 80, 0]) {
      const page = await browser.newPage({ viewport: { width: 900, height: 560 } });
      await installPaintedFrames(page);
      await page.addInitScript(() => {
        const w = window as unknown as Probe;
        w.__token = -1;
        w.__samples = [];
        w.__probe = (caller, following, atLatest) => {
          w.__samples.push({ token: w.__token, caller, following, atLatest });
        };
      });
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRowsSync" in window);
      await page.evaluate(async () => {
        const w = window as unknown as Probe;
        const rows = Array.from({ length: 40 }, (_, i) => ({
          id: `history-${i}`,
          kind: i % 2 ? "assistant" : "user",
          text: `Earlier message ${i}.`,
          version: 1,
          at: 1,
        }));
        w.__showRowsSync([
          ...rows,
          {
            id: "stream",
            kind: "assistant",
            text: "A streaming reply. ".repeat(100),
            streaming: true,
            version: 1,
            at: 1,
          },
        ]);
        for (let n = 0; n < 8; n++) await window.cmuxPaintFrame();
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
        Object.defineProperty(node, "scrollTop", {
          get() {
            return descriptor.get!.call(node);
          },
          set(top: number) {
            w.__samples.push({
              token: w.__token,
              caller: `write:${new Error().stack?.split("\n")[2]?.trim()}`,
              top,
            });
            descriptor.set!.call(node, top);
          },
          configurable: true,
        });
      });
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      if (distance) await page.mouse.wheel(0, -distance);
      await page.evaluate(async (distance) => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const until = performance.now() + 1100;
        do {
          await window.cmuxPaintFrame();
        } while (performance.now() < until);
        if (Math.abs(node.scrollHeight - node.clientHeight - node.scrollTop - distance) > 1)
          throw new Error(`Did not park at ${distance}: ${node.scrollHeight - node.clientHeight - node.scrollTop}`);
      }, distance);
      const result = await page.evaluate(async () => {
        const w = window as unknown as Probe;
        const rows = Array.from({ length: 40 }, (_, i) => ({
          id: `history-${i}`,
          kind: i % 2 ? "assistant" : "user",
          text: `Earlier message ${i}.`,
          version: 1,
          at: 1,
        }));
        let text = "A streaming reply. ".repeat(100);
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const start = node.scrollTop;
        for (let token = 0; token < 20; token++) {
          w.__token = token;
          text += "\n\nAnother streamed line.";
          w.__showRowsSync([
            ...rows,
            { id: "stream", kind: "assistant", text, streaming: true, version: token + 2, at: 1 },
          ]);
          for (let n = 0; n < 3; n++) await window.cmuxPaintFrame();
        }
        const samples = w.__samples.filter((s) => s.token >= 0);
        let following = [...w.__samples].reverse().find((s) => s.token < 0 && s.following !== undefined)?.following;
        let atLatest = [...w.__samples].reverse().find((s) => s.token < 0 && s.atLatest !== undefined)?.atLatest;
        let flips = 0;
        for (const s of samples) {
          if (s.following !== undefined) {
            if (following !== s.following) flips++;
            following = s.following;
          }
          if (s.atLatest !== undefined) {
            if (atLatest !== s.atLatest) flips++;
            atLatest = s.atLatest;
          }
        }
        return {
          flips,
          writes: samples.filter((s) => s.caller.startsWith("write:")).length,
          moved: node.scrollTop - start,
          gap: node.scrollHeight - node.clientHeight - node.scrollTop,
          following,
          callers: [...new Set(samples.map((s) => s.caller))],
          samples,
        };
      });
      if (process.env.CMUX_PARKED_CAPTURE && distance === 3)
        await page.screenshot({ path: process.env.CMUX_PARKED_CAPTURE });
      console.log(JSON.stringify({ distance, ...result }));
      results.push({ distance, ...result });
      if (distance) {
        // Only the reader's own trip back to the end may resume follow.
        if (distance === 80) {
          // A long scrollbar drag: start in the scroller, then move outside it after the press's
          // input window expires. Chromium owns the scroll event from the changed native offset.
          await page.mouse.down();
          await page.evaluate(async () => {
            const until = performance.now() + 1100;
            do {
              await window.cmuxPaintFrame();
            } while (performance.now() < until);
          });
          await page.mouse.move(1, 1);
          await page.locator(".acpmux-scroll").evaluate((node) => {
            node.scrollTop = node.scrollHeight;
          });
          await page.mouse.up();
        } else if (distance === 40) {
          await page.locator(".acpmux-scroll").evaluate((node) => {
            node.dispatchEvent(new TouchEvent("touchmove", { bubbles: true }));
            node.scrollTop = node.scrollHeight;
          });
        } else await page.mouse.wheel(0, 10000);
        await page.waitForFunction(() => {
          const w = window as unknown as Probe;
          return [...w.__samples].reverse().find((s) => s.following !== undefined)?.following === true;
        });
        const resumed = await page.evaluate(async () => {
          const w = window as unknown as Probe;
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const top = node.scrollTop;
          const rows = Array.from({ length: 40 }, (_, i) => ({
            id: `history-${i}`,
            kind: i % 2 ? "assistant" : "user",
            text: `Earlier message ${i}.`,
            version: 1,
            at: 1,
          }));
          w.__showRowsSync([
            ...rows,
            {
              id: "stream",
              kind: "assistant",
              text: "A streaming reply. ".repeat(100) + "\n\nAnother streamed line.".repeat(25),
              streaming: true,
              version: 30,
              at: 1,
            },
          ]);
          // Streaming markdown can reveal more rows after the first measurement. Observe its
          // settled end, rather than assuming that a fixed number of frames finishes the reveal.
          const deadline = performance.now() + 5000;
          do {
            await window.cmuxPaintFrame();
          } while (
            (node.scrollTop <= top || node.scrollHeight - node.clientHeight - node.scrollTop > 4) &&
            performance.now() < deadline
          );
          return {
            moved: node.scrollTop - top,
            gap: node.scrollHeight - node.clientHeight - node.scrollTop,
          };
        });
        expect(resumed.moved, `${distance}px reader resumed follow`).toBeGreaterThan(0);
        expect(resumed.gap).toBeLessThanOrEqual(4);
      }
      await page.close();
    }
    for (const result of results) {
      if (result.distance) {
        expect(result.flips, `${result.distance}px follow flips`).toBe(0);
        expect(result.writes, `${result.distance}px scroll writes`).toBe(0);
        expect(result.moved, `${result.distance}px parked offset`).toBe(0);
        expect(result.following).toBe(false);
      } else {
        expect(result.following).toBe(true);
        expect(result.gap).toBeLessThanOrEqual(4);
        expect(result.moved).toBeGreaterThan(100);
      }
    }
  });
  test("a 3px upward pointer or touch move releases follow before its scroll event", async () => {
    const results: { input: string; movement: number }[] = [];
    for (const input of ["pointer", "touch", "touch-pointer"] as const) {
      const page = await browser.newPage({ viewport: { width: 900, height: 560 } });
      await installPaintedFrames(page);
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRowsSync" in window);
      await page.evaluate(async () => {
        const w = window as unknown as Probe;
        const rows = Array.from({ length: 40 }, (_, i) => ({
          id: `history-${i}`,
          kind: i % 2 ? "assistant" : "user",
          text: `Earlier message ${i}.`,
          version: 1,
          at: 1,
        }));
        w.__showRowsSync([
          ...rows,
          { id: "stream", kind: "assistant", text: "A streaming reply.", streaming: true, version: 1, at: 1 },
        ]);
        for (let n = 0; n < 8; n++) await window.cmuxPaintFrame();
      });
      const parked = await page.evaluate(async (input) => {
        const w = window as unknown as Probe;
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const end = node.scrollHeight - node.clientHeight;
        if (input === "pointer" || input === "touch-pointer") {
          node.dispatchEvent(
            new PointerEvent("pointerdown", { bubbles: true, clientY: 300, buttons: 1, pointerId: 1 }),
          );
          node.dispatchEvent(
            new PointerEvent("pointermove", {
              bubbles: true,
              clientY: input === "touch-pointer" ? 303 : 297,
              buttons: 1,
              pointerId: 1,
              pointerType: input === "touch-pointer" ? "touch" : "mouse",
            }),
          );
        } else {
          const touch = (type: string, clientY: number) => {
            const event = new Event(type, { bubbles: true });
            Object.defineProperty(event, "touches", { value: [{ clientY }] });
            node.dispatchEvent(event);
          };
          touch("touchstart", 300);
          touch("touchmove", 303);
        }
        node.scrollTop = end - 3;
        const beforeEvent = node.scrollTop;
        w.__showRowsSync([
          { id: "history-0", kind: "user", text: "Earlier message 0.", version: 1, at: 1 },
          ...Array.from({ length: 39 }, (_, i) => ({
            id: `history-${i + 1}`,
            kind: (i + 1) % 2 ? "assistant" : "user",
            text: `Earlier message ${i + 1}.`,
            version: 1,
            at: 1,
          })),
          {
            id: "stream",
            kind: "assistant",
            text: "A streaming reply.\n\nA new streamed paragraph that grows.",
            streaming: true,
            version: 2,
            at: 1,
          },
        ]);
        for (let n = 0; n < 4; n++) await window.cmuxPaintFrame();
        return { beforeEvent, after: node.scrollTop, end: node.scrollHeight - node.clientHeight };
      }, input);
      results.push({ input, movement: Math.abs(parked.after - parked.beforeEvent) });
      await page.close();
    }
    console.log(`INPUT_RACE ${JSON.stringify(results)}`);
    for (const result of results)
      expect(result.movement, `${result.input} pre-scroll-event position`).toBeLessThanOrEqual(1);
  });

  test("painted geometry while parked through markdown, tools and above-viewport remeasurement", async () => {
    const results: { distance: number; falseFadeFrames: number }[] = [];
    for (const distance of [10, 20, 40, 80, 150]) {
      const page = await browser.newPage({ viewport: { width: 900, height: 560 } });
      await installPaintedFrames(page);
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html?painted`);
      await page.waitForFunction(() => "__showRowsSync" in window);
      await page.evaluate(async () => {
        const w = window as unknown as Probe;
        const rows = Array.from({ length: 40 }, (_, i) => ({
          id: `history-${i}`,
          kind: i % 2 ? "assistant" : "user",
          text: `Earlier message ${i}: keep this sentence in the same place.`,
          version: 1,
          at: 1,
        }));
        w.__showRowsSync([
          ...rows,
          {
            id: "stream",
            kind: "assistant",
            text: "I will inspect the renderer and explain the result.",
            streaming: true,
            version: 1,
            at: 1,
          },
        ]);
        (window as unknown as { __touchDock(queued: boolean): void }).__touchDock(false);
        for (let n = 0; n < 10; n++) await window.cmuxPaintFrame();
      });
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.wheel(0, -distance);
      const result = await page.evaluate(async () => {
        const w = window as unknown as Probe & { __geometry(caller: string, data: unknown): void };
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const until = performance.now() + 1100;
        do {
          await window.cmuxPaintFrame();
        } while (performance.now() < until);
        const events: { token: number; time: number; caller: string; data: unknown }[] = [];
        let token = -1;
        const log = (caller: string, data: unknown) => events.push({ token, time: performance.now(), caller, data });
        w.__probe = (caller, following, atLatest) => log(caller, { following, atLatest });
        w.__geometry = log;
        const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
        Object.defineProperty(node, "scrollTop", {
          get() {
            return descriptor.get!.call(node);
          },
          set(top: number) {
            log("write", { before: node.scrollTop, requested: top, stack: new Error().stack?.split("\n")[2] });
            descriptor.set!.call(node, top);
          },
          configurable: true,
        });
        const viewport = node.getBoundingClientRect();
        const articles = () => [...node.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
        const above = articles()
          .filter((r) => r.getBoundingClientRect().bottom <= viewport.top)
          .at(-1)?.dataset.rowId;
        const initial = new Set(articles().map((r) => r.dataset.rowId!));
        const identities = new Map(articles().map((r) => [r.dataset.rowId!, r]));
        const markers = new Map<string, Range>();
        for (const row of articles()) {
          const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
          let text: Node | null;
          while ((text = walker.nextNode()))
            if (text.textContent?.trim()) {
              const range = document.createRange();
              range.setStart(text, 0);
              range.setEnd(text, Math.min(8, text.textContent.length));
              markers.set(row.dataset.rowId!, range);
              break;
            }
        }
        const mutation = new MutationObserver((records) => {
          for (const record of records)
            for (const added of record.addedNodes)
              if (added instanceof Element) {
                const addedRows = [
                  ...(added.matches("[data-row-id]") ? [added] : []),
                  ...added.querySelectorAll("[data-row-id]"),
                ];
                for (const row of addedRows) {
                  const id = row.getAttribute("data-row-id")!;
                  log(identities.has(id) && identities.get(id) !== row ? "remount" : "mount", { id });
                  identities.set(id, row as HTMLElement);
                }
              }
        });
        mutation.observe(node, { subtree: true, childList: true });
        const shifts = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) log("layout-shift", JSON.parse(JSON.stringify(entry.toJSON())));
        });
        shifts.observe({ type: "layout-shift" });
        type Painted = {
          token: number;
          time: number;
          top: number;
          height: number;
          fade: string;
          mask: string;
          thread: string;
          rows: { id: string; top: number; bottom: number; text: number | null; opacity: string; translate: string }[];
        };
        const painted: Painted[] = [];
        const stop = window.cmuxAfterPaint((time) => {
          const visible = articles().filter((r) => {
            const b = r.getBoundingClientRect();
            return b.bottom > viewport.top && b.top < viewport.bottom;
          });
          const tracked = visible.length > 4 ? [visible[0], ...visible.slice(-3)] : visible;
          const style = getComputedStyle(node);
          painted.push({
            token,
            time,
            top: node.scrollTop,
            height: node.scrollHeight,
            fade: style.getPropertyValue("--acpmux-fade-bottom"),
            mask: style.maskImage,
            thread: node.querySelector<HTMLElement>(".acpmux-thread")?.style.top ?? "",
            rows: tracked.map((r) => {
              const b = r.getBoundingClientRect();
              const css = getComputedStyle(r);
              const range = markers.get(r.dataset.rowId!);
              return {
                id: r.dataset.rowId!,
                top: b.top,
                bottom: b.bottom,
                text: range?.startContainer.isConnected ? range.getBoundingClientRect().top : null,
                opacity: css.opacity,
                translate: css.translate,
              };
            }),
          });
          return true;
        });
        const rows = Array.from({ length: 40 }, (_, i) => ({
          id: `history-${i}`,
          kind: i % 2 ? "assistant" : "user",
          text: `Earlier message ${i}: keep this sentence in the same place.`,
          version: 1,
          at: 1,
        }));
        const chunks = [
          " The layout",
          " should keep",
          " the reader still.",
          "\n\n```ts\n",
          "const top =",
          " node.scrollTop;\n",
          "const delta = 0;\n",
          "```\n",
          "\n- inspect rows",
          "\n- preserve anchors",
          "\n- verify painted frames",
          "\n\nThe tool confirmed",
          " the measurements",
          " across all frames.",
        ];
        let text = "I will inspect the renderer and explain the result.";
        await window.cmuxPaintFrame();
        for (token = 0; token < chunks.length; token++) {
          text += chunks[token];
          // A late richer row above the viewport resolves from its old estimate to drawn height.
          // This is an actual row revision, not a mocked layout or scroll correction.
          const priorIndex = rows.findIndex((r) => r.id === above);
          const prior = rows[priorIndex];
          if (prior && [4, 8, 11].includes(token))
            rows[priorIndex] = {
              ...prior,
              text:
                prior.text +
                (token === 4
                  ? "\n\n```ts\nconst measured = true;"
                  : token === 8
                    ? "\n```\n\n- loaded detail"
                    : "\n- another measured line"),
              version: prior.version + 1,
            };
          const tool =
            token >= 10
              ? [
                  {
                    id: "tool",
                    kind: "activity",
                    version: token,
                    at: 1,
                    items: [
                      {
                        kind: "tool",
                        text: "",
                        tool: {
                          id: "read",
                          title: "Read renderer.ts",
                          kind: "read",
                          status: token < 12 ? "running" : "completed",
                        },
                      },
                    ],
                  },
                ]
              : [];
          w.__showRowsSync([
            ...rows,
            { id: "stream", kind: "assistant", text, streaming: true, version: token + 2, at: 1 },
            ...tool,
          ]);
          for (let n = 0; n < 4; n++) await window.cmuxPaintFrame();
        }
        for (let n = 0; n < 8; n++) await window.cmuxPaintFrame();
        stop();
        mutation.disconnect();
        shifts.disconnect();
        let jitter = 0,
          maxJitter = 0,
          scrollChanges = 0,
          fadeChanges = 0;
        const moves: unknown[] = [];
        for (let i = 1; i < painted.length; i++) {
          const a = painted[i - 1],
            b = painted[i];
          if (Math.abs(b.top - a.top) > 0.5) scrollChanges++;
          if (a.fade !== b.fade) fadeChanges++;
          for (const row of b.rows) {
            const old = a.rows.find((r) => r.id === row.id);
            if (!old || !initial.has(row.id)) continue;
            const delta = Math.max(
              Math.abs(row.top - old.top),
              row.text !== null && old.text !== null ? Math.abs(row.text - old.text) : 0,
            );
            if (delta > 0.5) {
              jitter++;
              maxJitter = Math.max(maxJitter, delta);
              moves.push({ token: b.token, id: row.id, delta, scroll: b.top - a.top, top: row.top, before: old.top });
            }
          }
        }
        return {
          above,
          falseFadeFrames: painted.filter((f) => f.fade === "56px" && f.height - node.clientHeight - f.top < 79).length,
          startGap: painted[0]?.height - node.clientHeight - painted[0]?.top,
          frames: painted.length,
          scrollChanges,
          writes: events.filter((e) => e.caller === "write").length,
          jitter,
          maxJitter,
          remounts: events.filter((e) => e.caller === "remount").length,
          commits: events.filter((e) => e.caller === "commit").length,
          shifts: events.filter((e) => e.caller === "layout-shift").length,
          fadeChanges,
          moves,
          painted,
          events,
        };
      });
      console.log(`PAINTED ${JSON.stringify({ distance, ...result })}`);
      results.push({ distance, falseFadeFrames: result.falseFadeFrames });
      await page.close();
    }
    for (const result of results) expect(result.falseFadeFrames, `${result.distance}px false jump/fade frame`).toBe(0);
  });
});
