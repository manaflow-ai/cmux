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
            if (!id.endsWith("/src/agent-session/acpmux/App.tsx")) return;
            let source = readFileSync(id, "utf8");
            const inserts = [
              ["followingRef.current = next;", 'globalThis.__probe?.("follow", next);'],
              ["followingRef.current = atLatest;", 'globalThis.__probe?.("queueScroll", atLatest, atLatest);'],
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
});
