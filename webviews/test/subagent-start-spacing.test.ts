// The room under a subagent's start line, in Chromium (gallery agent-pane.subagent-start-spacing).
// Leo, 2026-11-14 ~21:15Z, on "✧ Promote prod + auto delivery  started working" with the reply a turn
// gap under it: "the spacing after the subagent starting is inconsistent? it grows too big". The start
// line is a one-line row: whatever follows it stands where it stands under any one-line row, the
// transcript's own gaps (src/agent-session/acpmux/transcriptSpacing.ts): a reply the run gap away
// (step-to-prose), another line flush on the 22 pitch (step-pitch). Measured between visible marks,
// a text line's glyph-box centre to the next row's first line's, light theme, every variant.
// CMUX_TRANSCRIPT_SPACING_LOG=1 logs every drawn row's box and lines.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { TRANSCRIPT_SPACING } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-start-spacing.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.subagent-start-spacing";
  const VARIANTS = [
    "recorded",
    "then-text",
    "then-subagent",
    "then-tool",
    "reload-batches",
    "reload-older-batch",
  ] as const;
  const LOG = process.env.CMUX_TRANSCRIPT_SPACING_LOG === "1";
  const spec = (id: string) => TRANSCRIPT_SPACING.find((row) => row.id === id)!;
  const PROSE = spec("step-to-prose");
  const LINE = spec("step-pitch");

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("subagent start spacing", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "recorded" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measured = {
    /** Each start line and what follows it: the distance, and whether the next row is prose. */
    after: { gap: number; prose: boolean; next: string }[];
    rows: string[];
  };

  const measure = async (variant: string): Promise<Measured> => {
    const page = await browser.newPage({ viewport: { width: 1100, height: 1000 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900, theme: "Apple System Colors Light", reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    // A reload's second batch lands after the first paint (`pane.painted`): wait for the whole turn.
    if (variant.startsWith("reload"))
      await page.waitForFunction(
        () =>
          !!document.querySelector('[data-row-id*="start-reply"]') &&
          !!document.querySelector('[data-row-id*="start-prompt"]'),
        undefined,
        { timeout: 30_000 },
      );
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(
      () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(undefined)))),
    );
    const measured = await page.evaluate(() => {
      type Line = { top: number; bottom: number };
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
        }
        return true;
      };
      const lines = (scope: Element): Line[] => {
        const out: Line[] = [];
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.height === 0) continue;
            const same = out.find((line) => Math.abs((line.top + line.bottom) / 2 - (rect.top + rect.bottom) / 2) < 4);
            if (same) {
              same.top = Math.min(same.top, rect.top);
              same.bottom = Math.max(same.bottom, rect.bottom);
            } else out.push({ top: rect.top, bottom: rect.bottom });
          }
        }
        return out.sort((a, b) => a.top - b.top);
      };
      const centre = (line: Line | undefined) => (line ? (line.top + line.bottom) / 2 : null);
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll [data-row-id]")]
        .filter((row) => shown(row) && lines(row).length > 0)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      const after: { gap: number; prose: boolean; next: string }[] = [];
      rows.forEach((row, index) => {
        if (!row.querySelector(".cv-subagent-started")) return;
        const next = rows[index + 1];
        if (!next) return;
        const from = centre(lines(row).at(-1));
        const to = centre(lines(next)[0]);
        if (from === null || to === null) return;
        after.push({
          gap: Math.round((to - from) * 100) / 100,
          prose: next.classList.contains("acpmux-assistant"),
          next: next.dataset.rowId ?? "",
        });
      });
      const log = rows.map((row) => {
        const box = row.getBoundingClientRect();
        const kids = [...row.querySelectorAll<HTMLElement>("*")]
          .filter((kid) => kid.getBoundingClientRect().height > 0)
          .slice(0, 8)
          .map(
            (kid) =>
              `${kid.className.toString().split(" ")[0] || kid.tagName}:${kid.getBoundingClientRect().height.toFixed(1)}`,
          )
          .join(" ");
        return `${box.top.toFixed(2)}-${box.bottom.toFixed(2)} ${row.className} ${row.dataset.rowId} | lines ${lines(
          row,
        )
          .map((line) => ((line.top + line.bottom) / 2).toFixed(2))
          .join(",")} | ${kids}`;
      });
      return { after, rows: log };
    });
    await page.close();
    return measured;
  };

  for (const variant of VARIANTS)
    test(`${variant}: the row under a subagent's start line stands the transcript's gap from it`, async () => {
      const { after, rows } = await measure(variant);
      if (LOG || after.length === 0) console.log(`[${variant}]\n${rows.join("\n")}\n${JSON.stringify(after)}`);
      expect(after.length).toBeGreaterThan(0);
      for (const { gap, prose, next } of after) {
        const want = prose ? PROSE : LINE;
        if (next.startsWith("user-")) continue;
        if (Math.abs(gap - want.value) > want.tolerance) console.log(`[${variant}]\n${rows.join("\n")}`);
        expect({ next, gap: Math.abs(gap - want.value) <= want.tolerance ? want.value : gap }).toEqual({
          next,
          gap: want.value,
        });
      }
    });
});
