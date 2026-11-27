// l10n-allow-file: test assertions on the player's English labels, not shipped UI.
// A video's controls in agent chat each take their own click (Lawrence, relayed by Leo 2026-10-22:
// "trying to click between the two of them"). Open in tab and Expand were 24 px glass buttons 4 px
// apart in the frame's top corner, so a click meant for one met the other or, just off either, the
// poster under them (which plays the video with sound). And once it played, WebKit drew its own
// controls in that same corner (Mute, on a short or narrow video) with ours stacked over them.
//
// Measured in real layout, the pane's stylesheets on chips/ReplyMedia.tsx `MediaPlayer` playing the
// gallery's recording (test/browser/inline-video-controls.harness.tsx), with the pointer on it:
//   - every control's hit area is at least 28 x 28 px, and hit areas sit at least 8 px apart;
//   - a click anywhere on a control lands on it, nothing drawn over it;
//   - a click a few px off a control lands on nothing that acts (not its neighbour, not Play);
//   - while it plays, our controls keep clear of the native controls' rows: WebKit's inline controls
//     (WebCore modern-media-controls, inline-media-controls.css and media-controls.css) draw 31 px
//     bars 6 px inside the video, in its top corners (Full Screen and Picture in Picture at the left;
//     Mute at the right when the video is under 136 px tall or too narrow for it in the bottom bar)
//     and along its bottom.
// Real Chromium and WebKit; CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/inline-video-controls-browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("inline-video-controls-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`inline-video-controls: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("inline video controls", () => test("browsers", () => {}));
    return;
  }
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
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/inline-video-controls.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /// Opens the harness with the pointer resting on the video once its metadata is read (or the
  /// engine gave up on it: the controls draw the same either way).
  async function open(engine: string, query: string): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/inline-video-controls.html${query}`);
    await page.locator(".cv-media.is-video .cv-media__action").first().waitFor();
    await page.waitForFunction(() => {
      const video = document.querySelector<HTMLVideoElement>(".cv-media.is-video video");
      return Boolean(video && (video.readyState >= 1 || video.error));
    });
    return page;
  }

  /// Rests the pointer on the video's left edge (on no control), then waits for the controls to show.
  async function rest(page: Page) {
    const frame = (await page.locator(".cv-media__frame").boundingBox())!;
    await page.mouse.move(frame.x + 4, frame.y + frame.height / 2);
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".cv-media__actions")!).opacity === "1");
  }

  /// What breaks the rules, in words; empty when every control can be clicked on its own.
  const problems = (page: Page, playing: boolean) =>
    page.evaluate(
      ({ playing, MIN, GAP, NEAR, NATIVE }) => {
        const out: string[] = [];
        const media = document.querySelector<HTMLElement>(".cv-media.is-video")!;
        const video = media.querySelector("video")!.getBoundingClientRect();
        type Control = { name: string; rect: DOMRect; owner: Element };
        const controls: Control[] = [...media.querySelectorAll(".cv-media__action")].map((button) => ({
          name: button.getAttribute("aria-label") ?? "?",
          rect: button.getBoundingClientRect(),
          owner: button,
        }));
        const actions = [...controls];
        // Before it plays, the glass play button is Play's target (the whole poster plays it too).
        const lens = media.querySelector(".cv-media__play");
        if (lens) controls.push({ name: "Play", rect: lens.getBoundingClientRect(), owner: lens.closest("button")! });
        if (playing === Boolean(lens)) out.push(playing ? "the poster is still up" : "no Play button");
        const px = (value: number) => `${Math.round(value * 10) / 10} px`;
        const acting = (x: number, y: number) => document.elementFromPoint(x, y)?.closest("button, video") ?? null;
        for (const { name, rect } of controls)
          if (rect.width < MIN - 0.5 || rect.height < MIN - 0.5)
            out.push(`${name} is ${px(rect.width)} x ${px(rect.height)}`);
        for (let i = 0; i < controls.length; i++)
          for (let j = i + 1; j < controls.length; j++) {
            const [a, b] = [controls[i]!.rect, controls[j]!.rect];
            const apart = Math.max(a.left - b.right, b.left - a.right, a.top - b.bottom, b.top - a.bottom);
            if (apart < GAP - 0.5) out.push(`${controls[i]!.name} and ${controls[j]!.name} are ${px(apart)} apart`);
          }
        for (const { name, rect, owner } of controls) {
          const inset = 1;
          const points: [string, number, number][] = [
            ["middle", (rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2],
            ["top left", rect.left + inset, rect.top + inset],
            ["top right", rect.right - inset, rect.top + inset],
            ["bottom left", rect.left + inset, rect.bottom - inset],
            ["bottom right", rect.right - inset, rect.bottom - inset],
          ];
          for (const [where, x, y] of points) {
            const hit = acting(x, y);
            if (hit !== owner)
              out.push(
                `a click on ${name}'s ${where} lands on ${hit?.getAttribute("aria-label") ?? hit?.tagName ?? "nothing"}`,
              );
          }
        }
        // Just off a control is a miss, never a click on whatever is under it.
        for (const { name, rect, owner } of actions) {
          const midX = (rect.left + rect.right) / 2;
          const midY = (rect.top + rect.bottom) / 2;
          const points: [string, number, number][] = [
            ["left of", rect.left - NEAR, midY],
            ["right of", rect.right + NEAR, midY],
            ["above", midX, rect.top - NEAR],
            ["below", midX, rect.bottom + NEAR],
          ];
          for (const [where, x, y] of points) {
            const hit = acting(x, y);
            if (hit && hit !== owner)
              out.push(`a click ${NEAR} px ${where} ${name} lands on ${hit.getAttribute("aria-label") ?? hit.tagName}`);
          }
        }
        if (playing)
          for (const { name, rect } of actions) {
            // A short player cannot fit another row between both native control bars.
            if (video.height < 126) {
              if (rect.bottom > video.top - GAP + 0.5)
                out.push(`${name} overlaps a short player instead of sitting above it`);
              continue;
            }
            if (rect.top < video.top + NATIVE + GAP - 0.5)
              out.push(`${name} is ${px(rect.top - video.top)} from the top, in the native controls' corner row`);
            if (rect.bottom > video.bottom - NATIVE - GAP + 0.5)
              out.push(`${name} is ${px(video.bottom - rect.bottom)} from the bottom, on the native control bar`);
          }
        return out;
      },
      // The native rows: WebKit's 6 px inside margin plus its 31 px bar.
      { playing, MIN: 28, GAP: 8, NEAR: 3, NATIVE: 6 + 31 },
    );

  for (const [engine] of engines)
    for (const [label, query] of [
      ["in a reply", ""],
      ["in a tool's output", "?tool"],
      ["in a narrow column", "?width=300"],
      ["on a 100 px short video", "?height=100"],
      ["on a 180 px normal video", "?height=180"],
      ["on a 280 px tall video", "?height=280"],
    ] as const) {
      test(`${engine}, ${label}: before it plays, Open in tab, Expand and Play each take their own click`, async () => {
        const page = await open(engine, query);
        await rest(page);
        expect(await problems(page, false)).toEqual([]);
        await page.close();
      });

      test(`${engine}, ${label}: while it plays, Open in tab and Expand take their own click, clear of the player's controls`, async () => {
        const page = await open(engine, query);
        await rest(page);
        const before = await page.locator(".cv-media__frame").boundingBox();
        await page.locator("button.cv-media__poster").click();
        await page.locator(".cv-media__frame.is-playing").waitFor();
        await rest(page);
        expect(await page.locator(".cv-media__frame").boundingBox()).toEqual(before);
        expect(await problems(page, true)).toEqual([]);
        await page.close();
      });
    }
  for (const [engine] of engines) {
    test(`${engine}: a short video's Open in tab and Expand each perform only their own action`, async () => {
      const page = await open(engine, "?height=100");
      await rest(page);
      await page.getByRole("button", { name: "Open in tab", exact: true }).click();
      expect(await page.evaluate(() => (window as unknown as { __videoActions: string[] }).__videoActions)).toEqual([
        "link.openPath",
      ]);
      expect(await page.locator(".cv-media__frame.is-playing").count()).toBe(0);
      expect(await page.getByRole("dialog").count()).toBe(0);
      await page.getByRole("button", { name: "Expand", exact: true }).click();
      await page.getByRole("dialog").waitFor();
      expect(
        await page.evaluate(() => (window as unknown as { __videoActions: string[] }).__videoActions),
      ).toHaveLength(1);
      expect(await page.locator(".cv-media__frame.is-playing").count()).toBe(0);
      await page.close();
    });

    test(`${engine}: resizing a playing video moves its actions clear of the native controls`, async () => {
      const page = await open(engine, "?height=180");
      await rest(page);
      await page.locator("button.cv-media__poster").click();
      await page.locator(".cv-media__frame.is-playing").waitFor();
      expect(await problems(page, true)).toEqual([]);
      await page.locator("video").evaluate((video) => {
        video.style.height = "100px";
      });
      await page.waitForFunction(() => {
        const media = document.querySelector(".cv-media")!;
        return (
          media.querySelector(".cv-media__actions")!.getBoundingClientRect().bottom <=
          media.querySelector("video")!.getBoundingClientRect().top - 4
        );
      });
      await rest(page);
      expect(await problems(page, true)).toEqual([]);
      await page.close();
    });
  }
});
