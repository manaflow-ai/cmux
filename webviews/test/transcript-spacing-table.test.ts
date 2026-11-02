// The transcript's spacing against its settled table (src/agent-session/acpmux/transcriptSpacing.ts,
// leo-workspace design/transcript-spacing.md). Leo, 2026-11-02: "we need to like enforce the good
// versions when we find them later in the specs/comments/tests or something".
//
// Gallery entry agent-pane.transcript-spacing-table holds every row kind of his capture that day: a
// two-paragraph reply and its footer, an inbox row, a prompt, "Sent 3 messages", a one-line reply,
// "Ran 2 commands", an inbox row, the live line "Sending message to …" and the waiting group "2
// messages from 2 sessions". Each table row is measured in
// Chromium, light and dark, between visible marks (a text line's centre, a bubble's edge, an icon
// glyph's centre). A row marked `pending` is expected to fail until its PR lands (`test.failing`).
//
// CMUX_TRANSCRIPT_SPACING_LOG=1 logs every row's centre and every measured gap.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { BUBBLE, FOOTER, TRANSCRIPT_SPACING } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-spacing-table.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-spacing-table";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const LOG = process.env.CMUX_TRANSCRIPT_SPACING_LOG === "1";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript spacing table", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "shipped" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measured = {
    gaps: Record<string, number | null>;
    footer: { glyph: number; button: number; pitch: number | null; inkLeft: number; proseLeft: number } | null;
    bubble: { oneLine: number; paddingInline: number; radius: number } | null;
    rows: string[];
  };

  const measure = (page: Page): Promise<Measured> =>
    page.evaluate(() => {
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden") return false;
        }
        return true;
      };
      /** The glyph boxes of the shown text lines under `scope`, top to bottom, one per line. */
      const lines = (scope: Element | null | undefined): { top: number; bottom: number; left: number }[] => {
        if (!scope) return [];
        const out: { top: number; bottom: number; left: number }[] = [];
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
              same.left = Math.min(same.left, rect.left);
            } else out.push({ top: rect.top, bottom: rect.bottom, left: rect.left });
          }
        }
        return out.sort((a, b) => a.top - b.top);
      };
      const centre = (line: { top: number; bottom: number } | undefined) =>
        line ? (line.top + line.bottom) / 2 : null;
      /** The shown element whose own text holds `text`. */
      const holding = (text: string): HTMLElement | null => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode())
          if (node.textContent?.includes(text) && node.parentElement && shown(node.parentElement))
            return node.parentElement;
        return null;
      };
      const bubble = (text: string) =>
        holding(text)?.closest<HTMLElement>(".cv-user__bubble")?.getBoundingClientRect() ?? null;
      const paragraph = (text: string) => lines(holding(text)?.closest(".cv-md p, .cv-md li") ?? holding(text));

      /** The first line of every shown element whose own text holds `text`, top to bottom. */
      const everyLine = (text: string) => {
        const found: { top: number; bottom: number; left: number }[] = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode())
          if (node.textContent?.includes(text) && node.parentElement && shown(node.parentElement)) {
            const line = lines(node.parentElement)[0];
            if (line && !found.some((other) => Math.abs(other.top - line.top) < 1)) found.push(line);
          }
        return found.sort((x, y) => x.top - y.top);
      };

      const p1 = paragraph("The three lanes have their briefs");
      const p2 = paragraph("I'll land each as its review passes");
      const actions = [...document.querySelectorAll<HTMLElement>(".cv-turn-actions")].filter(shown)[0] ?? null;
      const glyphs = actions ? [...actions.querySelectorAll<SVGElement>("button svg")].filter(shown) : [];
      const buttons = actions ? [...actions.querySelectorAll<HTMLElement>("button")].filter(shown) : [];
      const glyph = glyphs[0]?.getBoundingClientRect() ?? null;
      /** The first line of the element holding `text`, only inside a row of kind `kind` (its
       * `acpmux-<kind>` class): a mark found in the wrong row kind measures as missing. */
      const lineIn = (text: string, kind: string) => {
        const element = holding(text);
        return element?.closest(`.acpmux-${kind}`) ? (lines(element)[0] ?? null) : null;
      };
      const inboxes = everyLine("inbox thread").filter((line) =>
        [...document.querySelectorAll(".acpmux-laneNoticeBatch")].some((row) => {
          const box = row.getBoundingClientRect();
          return line.top >= box.top && line.bottom <= box.bottom;
        }),
      );
      const prompt = bubble("Hand the three polish lanes");
      /** The drawn lines of the transcript row that holds `text`, top to bottom. */
      const rowLines = (text: string) => lines(holding(text)?.closest(".acpmux-row"));
      // A running turn lists a run's calls one line each; a finished one folds them ("Sent 3 messages").
      const sends = rowLines("Take the one-line row pitch");
      const short = paragraph("Briefs are out");
      const commands = rowLines("gh pr checks 2210").length ? rowLines("gh pr checks 2210") : rowLines("Checked #2210");
      const live = lineIn("Sending message to", "thinking");
      const waiting = lineIn("2 messages from 2 sessions", "pendingMessages");

      const diff = (a: number | null | undefined, b: number | null | undefined) =>
        a == null || b == null ? null : Math.round((b - a) * 100) / 100;
      const at = (line: { top: number; bottom: number } | null | undefined) => centre(line ?? undefined);
      const glyphCentre = glyph ? (glyph.top + glyph.bottom) / 2 : null;
      const gaps: Record<string, number | null> = {
        paragraph: diff(at(p1.at(-1)), at(p2[0])),
        "prose-to-footer": diff(at(p2.at(-1)), glyphCentre),
        "footer-to-next": diff(glyphCentre, at(inboxes[0])),
        "step-to-prompt": diff(at(inboxes[0]), prompt?.top),
        "prompt-to-step": diff(prompt?.bottom, at(sends[0])),
        "step-pitch": diff(at(sends[0]), at(sends[1])),
        "step-to-prose": diff(at(sends.at(-1)), at(short[0])),
        "prose-to-step": diff(at(short.at(-1)), at(commands[0])),
        "run-to-step": diff(at(commands.at(-1)), at(inboxes[1])),
        "step-to-live": diff(at(inboxes[1]), at(live)),
        "live-to-step": diff(at(live), at(waiting)),
      };

      const bubbleElement = holding("Hand the three polish lanes")?.closest<HTMLElement>(".cv-user__bubble");
      const style = bubbleElement ? getComputedStyle(bubbleElement) : null;
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].filter(shown).map((row) => {
        const box = row.getBoundingClientRect();
        const text = (row.innerText || "").replace(/\s+/g, " ").trim().slice(0, 60);
        return `${box.top.toFixed(2)}-${box.bottom.toFixed(2)} ${row.className.replace(/\s+/g, ".")} | ${text} | centres ${lines(
          row,
        )
          .map((line) => ((line.top + line.bottom) / 2).toFixed(2))
          .join(",")}`;
      });
      return {
        gaps,
        footer: glyph
          ? {
              glyph: Math.round(glyph.height * 100) / 100,
              button: Math.round((buttons[0]?.getBoundingClientRect().height ?? 0) * 100) / 100,
              pitch:
                buttons.length > 1
                  ? Math.round(
                      (buttons[1]!.getBoundingClientRect().left - buttons[0]!.getBoundingClientRect().left) * 100,
                    ) / 100
                  : null,
              inkLeft: glyph.left,
              proseLeft: p2[0]?.left ?? 0,
            }
          : null,
        bubble: style
          ? {
              oneLine: Math.round(bubbleElement!.getBoundingClientRect().height * 100) / 100,
              paddingInline: parseFloat(style.paddingLeft),
              radius: parseFloat(style.borderTopLeftRadius),
            }
          : null,
        rows,
      };
    });

  const open = async (theme: string) => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 1100 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "shipped", width: 1100, theme, reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    return page;
  };

  const measured = new Map<string, Measured>();
  const of = async (theme: (typeof THEMES)[number]) => {
    const known = measured.get(theme.file);
    if (known) return known;
    const page = await open(theme.name);
    try {
      const result = await measure(page);
      if (LOG)
        console.log(
          `TRANSCRIPT_SPACING_TABLE ${theme.file}\n${result.rows.join("\n")}\n${JSON.stringify({ ...result, rows: undefined })}`,
        );
      measured.set(theme.file, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const theme of THEMES) {
    for (const row of TRANSCRIPT_SPACING) {
      // Whatever its value, every row must find both marks: a pending row that measured nothing
      // would otherwise pass as its expected failure forever.
      test(`${row.id} finds both its marks (${theme.file})`, async () => {
        expect((await of(theme)).gaps[row.id]).not.toBeNull();
      });
      (row.pending ? test.failing : test)(`${row.id}: ${row.between} is ${row.value}px (${theme.file})`, async () => {
        const got = (await of(theme)).gaps[row.id]!;
        expect(Math.abs(got - row.value)).toBeLessThanOrEqual(row.tolerance);
      });
    }
    test(`finds the reply footer's buttons (two or more) and the prompt bubble (${theme.file})`, async () => {
      const measured = await of(theme);
      expect(measured.footer?.pitch ?? null).not.toBeNull();
      expect(measured.bubble).not.toBeNull();
    });
    (FOOTER.pending ? test.failing : test)(
      `the reply footer's buttons are ${FOOTER.button}px around ${FOOTER.glyph}px glyphs, touching, first glyph on the prose edge (${theme.file})`,
      async () => {
        const footer = (await of(theme)).footer;
        expect(footer!.glyph).toBeCloseTo(FOOTER.glyph, 0);
        expect(footer!.button).toBeCloseTo(FOOTER.button, 0);
        expect(footer!.pitch!).toBeCloseTo(FOOTER.pitch, 0);
        expect(Math.abs(footer!.inkLeft - footer!.proseLeft)).toBeLessThanOrEqual(1);
      },
    );
    (BUBBLE.pending ? test.failing : test)(
      `a one-line prompt bubble is ${BUBBLE.oneLine}px tall, ${BUBBLE.paddingInline}px in at the sides, with a ${BUBBLE.radius} radius (${theme.file})`,
      async () => {
        const bubble = (await of(theme)).bubble!;
        expect(Math.abs(bubble.oneLine - BUBBLE.oneLine)).toBeLessThanOrEqual(0.5);
        expect(bubble.paddingInline).toBe(BUBBLE.paddingInline);
        expect(bubble.radius).toBe(BUBBLE.radius);
      },
    );
  }
});
