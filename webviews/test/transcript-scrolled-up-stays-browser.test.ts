// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolled up, the reader stays where they are until they ask for the latest row (Leo, 2026-11-07:
// "if I'm in the middle of your prompt, should I get automatically sent down? ... if I was reading
// something else, like why would I want to push down? Like I can just click the jump to bottom
// button if I want.").
//
// Following comes back only on an explicit action (Jump to latest, a send, End) or the reader's own
// downward scroll that reaches the end. The transcript used to take any scroll down to within its
// 4 px deadband of the end as the reader's while any input of the last second was held: a press on
// text, a sideways wheel, a wheel an inner scroller took, an up key, or a pointer move after a press
// whose release never came. A layout change that moved the view down there in that second turned
// following back on, and the reply streaming next carried the reader to the bottom.
//
// Each case parks the reader up a streaming reply, gives one of those inputs, then moves the view
// down to 2 px over its end the way a layout change does (a write to the offset, no reader input).
// The reply then streams on: following stays off and the offset stays where it was. The explicit
// ways back (a wheel down to the end, End, Jump to latest, a send) still follow the reply.
//
// Real Chromium and WebKit from Playwright; CI fails the file when an engine cannot launch.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Probe = Window & {
  __showRowsSync(rows: unknown[]): void;
  __send(): void;
  __followSnapshot(): { following: boolean; arms: { path: string; input: string | null }[] };
  __stream(): void;
};

await requireBrowserLane("transcript-scrolled-up-stays-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][])
    if (await probeEngineOrSkip("transcript-scrolled-up-stays-browser.test.ts", engine[0], engine[1]))
      engines.push(engine);
  if (engines.length === 0) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
      plugins: [
        {
          // The pane's Jump to latest, which the harness leaves off.
          name: "jump-button",
          enforce: "pre",
          transform(code, id) {
            if (id.endsWith("/test/browser/transcript-follow.harness.tsx"))
              return code.replace("<VirtualTranscript", "<VirtualTranscript jumpButton");
          },
        },
      ],
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const frames = (page: Page, count = 4) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  const view = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const { following, arms } = (window as unknown as Probe).__followSnapshot();
      return { top: node.scrollTop, fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop, following, arms };
    });

  /// A chat with a reply streaming, the reader parked `distance` px up it with a real wheel, and
  /// the wheel's input hold over (so only the case's own input is held).
  async function parked(name: string, distance: number) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 600 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRowsSync" in window);
    await page.evaluate(() => {
      const w = window as unknown as Probe;
      const history = Array.from({ length: 30 }, (_, i) => ({
        id: `history-${i}`,
        kind: i % 2 ? "assistant" : "user",
        text:
          i % 2 ? `Answer ${i}. ${"The keeper wiped the salt from the lantern glass. ".repeat(3)}` : `Question ${i}?`,
        version: 1,
        at: 1,
      }));
      let text = "A streaming reply. ".repeat(60);
      let version = 1;
      w.__stream = () => {
        text += `\n\nAnother streamed paragraph ${version}. ${"More words arrive. ".repeat(5)}`;
        version += 1;
        w.__showRowsSync([...history, { id: "stream", kind: "assistant", text, streaming: true, version, at: 1 }]);
      };
      w.__stream();
    });
    await frames(page, 10);
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.wheel(0, -distance);
    // The wheel's own input hold (userScroll.ts USER_SCROLL_INTENT_MS) lapses: each case holds only its own input.
    // fixed-wait: the one-second input hold is the behavior under test.
    await page.waitForTimeout(1_150);
    await frames(page);
    const start = await view(page);
    expect(start.following, `${name}: parked ${distance}px up`).toBe(false);
    return { page, box };
  }

  /// Resolves once the view is at rest: no finite animation running (a glide, a fold), and three
  /// painted frames in a row with the same offset and height.
  const settled = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 5_000;
          window.cmuxAfterPaint(() => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const moving = node
              .getAnimations({ subtree: true })
              .some((each) => each.playState === "running" && each.effect?.getTiming().iterations !== Infinity);
            const now = `${Math.round(node.scrollTop)} ${node.scrollHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3 || performance.now() > deadline) {
              done();
              return false;
            }
          });
        }),
    );
  /// A layout change moves the view down to 2 px over its end: a write to the offset, no input.
  const layoutScrollToEnd = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.scrollTop = node.scrollHeight - node.clientHeight - 2;
    });
  const streamOn = async (page: Page, chunks = 6) => {
    for (let chunk = 0; chunk < chunks; chunk++) {
      await page.evaluate(() => (window as unknown as Probe).__stream());
      await frames(page, 3);
    }
  };
  /// A history row's text in view, away from any control.
  async function textInView(page: Page) {
    return page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const box = node.getBoundingClientRect();
      const row = [...node.querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="history-"] p')].find((each) => {
        const rect = each.getBoundingClientRect();
        return rect.top > box.top + 20 && rect.bottom < box.top + box.height / 2;
      })!;
      const rect = row.getBoundingClientRect();
      return { x: rect.left + 12, y: rect.top + rect.height / 2 };
    });
  }

  /// Inputs that are not the reader scrolling down, each held for a second by the scroll intent.
  const notDown: Record<
    string,
    (page: Page, box: { x: number; y: number; width: number; height: number }) => Promise<void>
  > = {
    "a press on text": async (page) => {
      const at = await textInView(page);
      await page.mouse.click(at.x, at.y);
    },
    "a sideways wheel": async (page, box) => {
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 3);
      await page.mouse.wheel(60, 0);
    },
    "a wheel an inner scroller takes": async (page) => {
      const at = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const box = node.getBoundingClientRect();
        const row = [...node.querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="history-"]')].find(
          (each) => each.getBoundingClientRect().top > box.top + 20,
        )!;
        const inner = document.createElement("div");
        inner.id = "inner-scroller";
        inner.style.cssText = "height:60px;overflow:auto";
        inner.innerHTML = '<div style="height:600px">output</div>';
        row.append(inner);
        const rect = inner.getBoundingClientRect();
        return { x: rect.left + 20, y: rect.top + 30 };
      });
      await page.mouse.move(at.x, at.y);
      await page.mouse.wheel(0, 40);
      await frames(page);
      expect(await page.evaluate(() => document.getElementById("inner-scroller")!.scrollTop)).toBeGreaterThan(0);
    },
    "an up key": async (page) => {
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.keyboard.press("ArrowUp");
    },
    "a pointer move after a press whose release never came": async (page) => {
      const at = await textInView(page);
      await page.evaluate(({ x, y }) => {
        const target = document.elementFromPoint(x, y)!;
        target.dispatchEvent(
          new PointerEvent("pointerdown", {
            bubbles: true,
            composed: true,
            clientX: x,
            clientY: y,
            buttons: 1,
            isPrimary: true,
          }),
        );
      }, at);
      // Hovering on: the first move reports no button down, and the press counts as released.
      await page.mouse.move(at.x + 40, at.y + 10, { steps: 3 });
    },
  };

  for (const [name] of engines)
    for (const [input, give] of Object.entries(notDown))
      for (const distance of [30, 90])
        test(`${name}: ${input}, then a layout change to the end ${distance}px up, keeps the reader's place`, async () => {
          // fixed-wait: parked() lets the wheel's one-second input hold lapse.
          const { page, box } = await parked(name, distance);
          await give(page, box);
          await layoutScrollToEnd(page);
          await frames(page, 6);
          const landed = await view(page);
          await streamOn(page);
          const after = await view(page);
          await page.close();
          expect({ following: after.following, moved: after.top - landed.top, arms: after.arms }).toEqual({
            following: false,
            moved: 0,
            arms: [],
          });
          // The reply grew below the reader, out of view.
          expect(after.fromEnd).toBeGreaterThan(40);
        });

  /// The explicit ways back to the latest row: each follows the reply that streams on.
  const backToLatest: Record<
    string,
    (page: Page, box: { x: number; y: number; width: number; height: number }) => Promise<string>
  > = {
    "a wheel down to the end": async (page, box) => {
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.wheel(0, 4000);
      return "reader-scroll";
    },
    "End, the page focused": async (page) => {
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.keyboard.press("End");
      return "end-key";
    },
    "Cmd-Down on a row": async (page) => {
      const at = await textInView(page);
      await page.mouse.click(at.x, at.y);
      await page.keyboard.press("Meta+ArrowDown");
      return "end-key";
    },
    "End on a row": async (page) => {
      // A row the reader picked takes the keys (the transcript's roving tab stop); End goes to the last.
      const at = await textInView(page);
      await page.mouse.click(at.x, at.y);
      await page.keyboard.press("End");
      return "end-key";
    },
    "Jump to latest": async (page) => {
      await page.locator(".acpmux-jump-latest[data-shown]").click();
      return "jump";
    },
    "a send": async (page) => {
      await page.evaluate(() => (window as unknown as Probe).__send());
      return "send";
    },
  };
  for (const [name] of engines)
    for (const [action, take] of Object.entries(backToLatest))
      test(`${name}: ${action} goes back to the latest row and follows it`, async () => {
        // fixed-wait: parked() lets the wheel's one-second input hold lapse.
        const { page, box } = await parked(name, 200);
        const path = await take(page, box);
        await settled(page);
        await streamOn(page);
        // Following waits out the reader's own input hold (followDeferred) before it settles at the end.
        await page
          .waitForFunction(
            () => {
              const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              return node.scrollHeight - node.clientHeight - node.scrollTop <= 4;
            },
            undefined,
            { timeout: 4_000 },
          )
          .catch(() => {});
        await settled(page);
        const after = await view(page);
        await page.close();
        expect(after.following).toBe(true);
        expect(after.fromEnd).toBeLessThanOrEqual(4);
        // followTrace names what brought following back.
        expect(after.arms.at(-1)?.path).toBe(path);
      });
});
