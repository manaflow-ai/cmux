// l10n-allow-file: synthetic gallery fixture and test labels, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { chromium, type Browser } from "playwright";
import { createServer, type ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { playFailures } from "./support/galleryPlay";
import type { PlayReport } from "../src/gallery/play";

await requireBrowserLane("pr-dock-inline-layout.test.ts", () => {
  setDefaultTimeout(120_000);
  const captures = process.env.CMUX_PR_DOCK_CAPTURE ?? path.resolve(import.meta.dir, "../artifacts/pr-dock");
  let browser: Browser;
  let vite: ViteDevServer;
  beforeAll(async () => {
    mkdirSync(captures, { recursive: true });
    browser = await chromium.launch({ headless: true });
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, ["agent-pane.pr-dock", "agent-pane.bottom-stack"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    execFileSync("tar", ["-czf", `${captures}.tgz`, "-C", captures, "."]);
  });

  for (const theme of ["Apple System Colors", "Apple System Colors Light"])
    for (const width of [760, 320])
      test(`pr-queue fallback at ${width}px in ${theme} keeps PR links before any assistant reply`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 660 } });
        const geometry = () =>
          page.evaluate(() => {
            const rect = (selector: string) => {
              const { x, y, width, height, bottom } = document.querySelector(selector)!.getBoundingClientRect();
              return { x, y, width, height, bottom };
            };
            return {
              queue: rect(".acpmux-composer-queue"),
              fallback: rect(".acpmux-pr-fallback"),
              bar: rect(".acpmux-composer-bar"),
            };
          });
        let before: Awaited<ReturnType<typeof geometry>> | undefined;
        try {
          await page.exposeFunction("cmuxGalleryInput", async (action: { kind: string; x: number; y: number }) => {
            if (action.kind !== "click") throw new Error(`Unexpected PR-queue input: ${action.kind}`);
            before = await geometry();
            await page.mouse.click(action.x, action.y);
          });
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.bottom-stack", {
              variant: "pr-queue",
              width,
              theme,
            })}`,
          );
          await page.locator(".acpmux-pr-fallback .acpmux-pr-dock").waitFor({ timeout: 10_000 });
          await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
          const report = await page.evaluate(() =>
            JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport ?? {}),
          );
          expect(before).toBeDefined();
          const after = await geometry();
          const growth = after.queue.height - before!.queue.height;
          expect(growth).toBeGreaterThanOrEqual(-1);
          expect(Math.abs(after.fallback.y - before!.fallback.y + growth)).toBeLessThanOrEqual(1);
          for (const key of ["x", "width", "height"] as const)
            expect(Math.abs(after.fallback[key] - before!.fallback[key])).toBeLessThanOrEqual(1);
          for (const key of ["x", "y", "width", "height"] as const)
            expect(Math.abs(after.bar[key] - before!.bar[key])).toBeLessThanOrEqual(1);
          expect(before!.fallback.bottom).toBeLessThanOrEqual(before!.queue.y + 1);
          expect(after.fallback.bottom).toBeLessThanOrEqual(after.queue.y + 1);
          // This click expands the queued prompt, not the PR overflow. Only the form growing
          // upward and its fallback following it are expected; all other shift sources and
          // directions stay failures. The precise movement and fixed bar are checked above.
          const measured = JSON.parse(report) as PlayReport;
          for (const step of measured.steps ?? []) {
            const expected =
              step.step === "click .acpmux-queued" &&
              step.shifts.length > 0 &&
              step.shifts.every(
                (shift) =>
                  shift.sources.length > 0 &&
                  shift.sources.every((source) => {
                    const match =
                      /^(form\.acpmux-composer|div\.acpmux-transcript-after-latest) \[(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+)\]$/.exec(
                        source,
                      );
                    if (!match) return false;
                    const [x, y, width, height] = match.slice(2).map(Number);
                    return (
                      x === 0 && width === 0 && y! <= 0 && height === (match[1] === "form.acpmux-composer" ? -y! : 0)
                    );
                  }),
              );
            if (expected) step.problems = step.problems.filter((problem) => !problem.startsWith("layout shift "));
          }
          expect(playFailures(JSON.stringify(measured))).toEqual([]);
          expect(await page.locator(".acpmux-assistant").count()).toBe(0);
          expect(await page.locator(".acpmux-pr-dock").count()).toBe(1);
          const link = page.locator(".acpmux-pr-dock__bar");
          expect(await link.getAttribute("href")).toBe("https://github.com/acme/atlas-web/pull/128");
          const rect = (await link.boundingBox())!;
          expect(rect.x).toBeGreaterThanOrEqual(0);
          expect(rect.x + rect.width).toBeLessThanOrEqual(width);
          await page.screenshot({
            path: `${captures}/pr-queue-${width}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
          });
        } finally {
          await page.close();
        }
      });

  for (const theme of ["Apple System Colors", "Apple System Colors Light"])
    test(`revealed prefix keeps a PR fallback in ${theme}`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 660 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", {
            variant: "streaming-fence-opener",
            width: 760,
            theme,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-pr-fallback .acpmux-pr-dock").waitFor();
        await page.evaluate(async () => {
          const revealPath = "/gallery/src/agent-session/acpmux/conversation/RevealedMarkdown.tsx";
          const fixturePath = "/gallery/src/agent-session/acpmux/summary/PullRequestDock.gallery.ts";
          const { revealFrames } = await import(/* @vite-ignore */ revealPath);
          const { default: entry } = await import(/* @vite-ignore */ fixturePath);
          // Freeze only the reply's reveal frames; layout and the rest of the pane still run.
          revealFrames.request = () => 1;
          revealFrames.cancel = () => {};
          const snapshot = structuredClone(entry.variants["streaming-fence-opener"].snapshot);
          const reply = snapshot.rows.find((row: { kind: string }) => row.kind === "assistant");
          reply.text = "```ts\nconst ready = true;\n";
          reply.version += 1;
          window.cmuxAcpmuxBridge!.receive(snapshot);
        });
        await page.waitForFunction(() => document.querySelector(".acpmux-assistant .cv-md")?.textContent === "");
        // Wait for the snapshot's React commit, with reveal still held at its empty safe prefix.
        await page.evaluate(
          () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
        );
        await page.screenshot({
          path: `${captures}/revealed-prefix-${theme.endsWith("Light") ? "light" : "dark"}.png`,
        });
        expect(await page.locator(".acpmux-pr-dock").count()).toBe(1);
        expect(await page.locator(".acpmux-pr-fallback .acpmux-pr-dock__bar").count()).toBe(1);
      } finally {
        await page.close();
      }
    });

  for (const width of [760, 320])
    test(`${width}px: PR pills share the action row and overflow never moves the transcript`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 420 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: "inline-pills", width })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const dock = page.locator(".acpmux-pr-dock");
        await dock.waitFor();
        await page.screenshot({
          type: "jpeg",
          quality: 75,
          path: `${captures}/closed-${width}.jpg`,
        });
        expect(await dock.evaluate((node) => !!node.closest(".cv-turn-actions"))).toBe(true);
        expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBeGreaterThan(0);
        expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBeLessThanOrEqual(2);
        expect(await dock.locator(".acpmux-pr-dock__dismiss").count()).toBe(0);
        const geometry = () =>
          page.evaluate(() =>
            [...document.querySelectorAll(".acpmux-row, .acpmux-composer")].map((node) => {
              const box = node.getBoundingClientRect();
              return { y: box.y, height: box.height };
            }),
          );
        const before = await geometry();
        const more = dock.locator(".acpmux-pr-dock__more");
        await more.click();
        await page.locator(".acpmux-pr-dock__popover").waitFor();
        expect(await geometry()).toEqual(before);
        expect(await page.locator(".acpmux-pr-dock__popover .acpmux-pr-dock__bar").count()).toBe(
          4 - (await dock.locator(".acpmux-pr-dock__bar").count()),
        );
        await page.screenshot({
          type: "jpeg",
          quality: 75,
          path: `${captures}/open-${width}.jpg`,
        });
        await page.keyboard.press("Escape");
        expect(await more.getAttribute("aria-expanded")).toBe("false");
        await page.waitForFunction(() => document.activeElement?.matches(".acpmux-pr-dock__more"));
        expect(await geometry()).toEqual(before);
      } finally {
        await page.close();
      }
    });
  for (const variant of ["empty-quote", "reply-actions"])
    test(`${variant} keeps one PR host in the existing row or fallback`, async () => {
      const page = await browser.newPage({ viewport: { width: 320, height: 660 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant, width: 320 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-pr-dock").waitFor();
        expect(await page.locator(".acpmux-pr-dock").count()).toBe(1);
        expect(await page.locator(".cv-md .acpmux-pr-dock").count()).toBe(0);
        const host = variant === "empty-quote" ? ".acpmux-pr-fallback" : ".cv-reply-actions";
        expect(await page.locator(`${host} .acpmux-pr-dock`).count()).toBe(1);
        const effectiveOpacity = await page.locator(`${host} .acpmux-pr-dock`).evaluate((node) => {
          let opacity = 1;
          for (let element: Element | null = node; element; element = element.parentElement)
            opacity *= Number(getComputedStyle(element).opacity);
          return opacity;
        });
        expect(effectiveOpacity).toBe(1);
        if (variant === "reply-actions") {
          const controls = page.locator(".cv-reply-actions > .cv-turn-action-group");
          expect(await controls.evaluate((node) => getComputedStyle(node).opacity)).toBe("0");
          await page.locator(".acpmux-assistant").hover();
          expect(await controls.evaluate((node) => getComputedStyle(node).opacity)).toBe("1");
        }
        await page.screenshot({ path: `${captures}/${variant}-320.png` });
      } finally {
        await page.close();
      }
    });
  for (const variant of [
    "inline-above-show-more",
    "inline-beside-show-more",
    "inline-below-show-more",
    "compact-count",
    "none-session-info",
    "collapsed-line",
    "full-bars",
    "just-merged",
    "several",
    "long-title",
  ])
    test(`preserved comparison ${variant} uses its original PR treatment`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 660 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant, width: 760 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        expect(await page.locator(".acpmux-pr-dock").count()).toBe(0);
        if (variant === "none-session-info") {
          expect(await page.locator(".acpmux-pr-comparison").count()).toBe(0);
        } else {
          await page.locator(".acpmux-pr-comparison").waitFor();
          expect(await page.locator(".acpmux-pr-comparison").count()).toBe(1);
          const mode =
            variant.startsWith("inline-") || variant === "compact-count"
              ? "compact"
              : variant === "collapsed-line"
                ? "collapsed"
                : "full";
          expect(await page.locator(".acpmux-pr-comparison").getAttribute("data-mode")).toBe(mode);
          if (variant !== "compact-count")
            expect(await page.locator(".acpmux-pr-comparison__bar:visible").count()).toBeGreaterThan(0);
        }
      } finally {
        await page.close();
      }
    });
  for (const variant of ["whitespace-reply", "streaming-fence-opener"])
    test(`${variant} keeps the fallback PR pill`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 660 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant, width: 760 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        expect(await page.locator(".acpmux-assistant .cv-md").count()).toBe(1);
        expect(await page.locator(".acpmux-assistant .cv-md").textContent()).toBe("");
        expect(await page.locator(".acpmux-pr-fallback .acpmux-pr-dock").count()).toBe(1);
        expect(await page.locator(".acpmux-pr-fallback .acpmux-pr-dock__bar").count()).toBe(1);
      } finally {
        await page.close();
      }
    });
  for (const variant of [
    "no-footer",
    "received",
    "one-first",
    "tight",
    "code-tail",
    "table-tail",
    "math-tail",
    "rule-tail",
    "diagram-tail",
    "notes-tail",
  ])
    for (const width of [760, 320])
      test(`${variant} at ${width}px keeps content and pills within the message`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 660 } });
        try {
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant, width })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-pr-dock").waitFor();
          expect(await page.locator(".acpmux-pr-dock").count()).toBe(1);
          await page.screenshot({
            type: "jpeg",
            quality: 75,
            path: `${captures}/${variant}-${width}.jpg`,
          });
          const boxes = await page.locator(".acpmux-pr-dock").evaluate((node) => {
            const row = node.closest(".acpmux-row")!.getBoundingClientRect();
            return [...node.querySelectorAll("a,button")].map((child) => {
              const rect = child.getBoundingClientRect();
              return { left: rect.left >= row.left, right: rect.right <= row.right + 1 };
            });
          });
          for (const box of boxes) expect(box).toEqual({ left: true, right: true });
          if (variant === "notes-tail") {
            expect(await page.locator(".cv-footnote").last().locator(".acpmux-pr-dock").count()).toBe(1);
          }
          if (variant === "no-footer") {
            const widths = await page.locator(".acpmux-assistant").evaluate((node) => {
              const md = node.querySelector(".cv-md")!;
              return {
                body: md.getBoundingClientRect().width,
                paragraph: md.querySelector(".cv-p")!.getBoundingClientRect().width,
                code: md.querySelector(".cv-codeblock")!.getBoundingClientRect().width,
              };
            });
            expect(widths.paragraph).toBe(widths.body);
            expect(widths.code).toBe(widths.body);
          }
        } finally {
          await page.close();
        }
      });
  for (const theme of ["Apple System Colors", "Apple System Colors Light"])
    test(`table-tail at 760px in ${theme} resets the wrapped block margin`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 660 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", {
            variant: "table-tail",
            width: 760,
            theme,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".cv-table-block").waitFor();
        expect(await page.locator(".acpmux-pr-dock").count()).toBe(1);
        await page.screenshot({
          path: `${captures}/table-tail-${theme.endsWith("Light") ? "light" : "dark"}-760.png`,
        });
        const margins = await page.locator(".cv-table-block").evaluate((node) => {
          const style = getComputedStyle(node);
          return { top: style.marginTop, bottom: style.marginBottom };
        });
        expect(margins.top).toBe("0px");
        expect(margins.bottom).toBe("0px");
      } finally {
        await page.close();
      }
    });
  // Many PRs (Leo's "+53" row): stills at 2x for the PR body, before and after. Captures only;
  // the assertions are the tests below, so this also runs on the base renderer.
  for (const theme of ["Apple System Colors", "Apple System Colors Light"])
    for (const variant of ["readable-titles", "numbers-only", "inline-last-line"])
      test(`${variant} still in ${theme}`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2 });
        const tone = theme.endsWith("Light") ? "light" : "dark";
        try {
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant, width: 760, theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-pr-dock").waitFor();
          await page.evaluate(
            () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
          );
          await page.screenshot({ path: `${captures}/many-${variant}-${tone}.png` });
          const more = page.locator(".acpmux-pr-dock__more").last();
          if (await more.count()) {
            await more.click();
            await page.locator(".acpmux-pr-dock__popover").waitFor();
            await page.screenshot({ path: `${captures}/many-${variant}-${tone}-open.png` });
          }
        } finally {
          await page.close();
        }
      });

  /// Every drawn chip's title, its drawn width and whole width, and the least readable width (12ch).
  const chips = (page: import("playwright").Page, scope: string) =>
    page.evaluate((scope) => {
      const probe = document.createElement("span");
      probe.style.cssText = "position:absolute;visibility:hidden;width:12ch";
      const host = document.querySelector(scope)!;
      host.appendChild(probe);
      const readable = probe.getBoundingClientRect().width;
      probe.remove();
      return [...host.querySelectorAll<HTMLElement>(".acpmux-pr-dock__bar")].map((bar) => {
        const title = bar.querySelector<HTMLElement>(".acpmux-pr-dock__title");
        return {
          number: bar.querySelector(".acpmux-pr-dock__number")?.textContent ?? "",
          title: title?.textContent ?? null,
          drawn: title?.getBoundingClientRect().width ?? 0,
          whole: title?.scrollWidth ?? 0,
          readable,
        };
      });
    }, scope);

  for (const theme of ["Apple System Colors", "Apple System Colors Light"])
    for (const width of [760, 420, 320])
      test(`${width}px in ${theme}: 55 PRs read as numbers or readable titles, on their own right-aligned line`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 660 } });
        try {
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: "readable-titles", width, theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const dock = page.locator(".acpmux-pr-dock");
          await dock.waitFor();
          expect(await dock.count()).toBe(1);
          const drawn = await chips(page, ".acpmux-pr-dock");
          expect(drawn.length).toBeGreaterThanOrEqual(1);
          expect(drawn.length).toBeLessThanOrEqual(2);
          for (const chip of drawn) {
            expect(chip.number).toMatch(/^#\d+$/);
            // A title is whole, or cut no shorter than 12 characters: never "cm…".
            if (chip.title !== null) expect(chip.drawn + 1).toBeGreaterThanOrEqual(Math.min(chip.whole, chip.readable));
          }
          if (width === 760) expect(drawn.every((chip) => chip.title)).toBe(true);
          // Its own line, right-aligned under the reply's last words.
          const place = await dock.evaluate((node) => {
            const paragraph = node.closest(".cv-p, p, li") ?? node.parentElement!.parentElement!;
            const text = document.createRange();
            text.selectNodeContents(paragraph);
            text.setEndBefore(node.parentElement!);
            const lines = [...text.getClientRects()].filter((rect) => rect.width > 0);
            const last = lines.at(-1)!;
            const dockBox = node.getBoundingClientRect();
            const row = paragraph.getBoundingClientRect();
            return {
              lastBottom: last.bottom,
              dockTop: dockBox.top,
              dockRight: dockBox.right,
              rowRight: row.right,
              line: !!node.closest(".cv-tail-line"),
            };
          });
          expect(place.line).toBe(true);
          expect(place.dockTop).toBeGreaterThanOrEqual(place.lastBottom - 1);
          expect(Math.abs(place.dockRight - place.rowRight)).toBeLessThanOrEqual(2);
          // The overflow lists every PR the row left out, each with its title, inside the viewport.
          const more = dock.locator(".acpmux-pr-dock__more");
          expect(await more.innerText()).toBe(`+${55 - drawn.length}`);
          await more.click();
          const list = page.locator(".acpmux-pr-dock__popover .acpmux-pr-dock__list");
          await list.waitFor();
          expect(await more.getAttribute("aria-expanded")).toBe("true");
          const listed = await chips(page, ".acpmux-pr-dock__popover");
          expect(listed.length).toBe(55 - drawn.length);
          expect(listed.every((chip) => chip.title && chip.title.length > 12)).toBe(true);
          const numbers = new Set([...drawn, ...listed].map((chip) => chip.number));
          expect(numbers.size).toBe(55);
          const box = await list.evaluate((node) => {
            const rect = node.getBoundingClientRect();
            return { top: rect.top, bottom: rect.bottom, scrolls: node.scrollHeight > node.clientHeight };
          });
          expect(box.top).toBeGreaterThanOrEqual(0);
          expect(box.bottom).toBeLessThanOrEqual(660);
          expect(box.scrolls).toBe(true);
          await page.keyboard.press("Escape");
          expect(await more.getAttribute("aria-expanded")).toBe("false");
        } finally {
          await page.close();
        }
      });

  test("a chip's hover card gives its whole title", async () => {
    const page = await browser.newPage({ viewport: { width: 320, height: 660 } });
    try {
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: "numbers-only", width: 320 })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const chip = page.locator(".acpmux-pr-dock .acpmux-pr-dock__bar").first();
      await chip.waitFor();
      expect(await chip.locator(".acpmux-pr-dock__title").count()).toBe(0);
      await chip.hover();
      const card = page.locator(".acpmux-pr-card");
      await card.waitFor({ timeout: 5_000 });
      expect(await card.innerText()).toContain("Retry uploads on transient failures");
    } finally {
      await page.close();
    }
  });
});
