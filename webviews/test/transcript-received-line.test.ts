// l10n-allow-file: test fixtures.
// Another machine's lane's message under a reply's footer, then the turn it started folded to "Ran 2
// commands, received a message" (gallery agent-pane.transcript-spacing-table, variant peer-lines).
// Leo, 2026-11-02, on that capture: "wtf these tool call spacing things are still weird". The
// received line is a one-line row like any tool row (leo-workspace design/chat-transcript.md, "One-line
// row pitch"; design/transcript-spacing.md): the same 22px line and text size, its mark on the shared
// icon column, the sender named once ("merge-timeout · lane-vm-01", never "lane-vm-01/merge-timeout
// · lane-vm-01"), and the footer's room above it (transcriptSpacing.ts `footer-to-next`).
//
// CMUX_TRANSCRIPT_RECEIVED_LOG=1 logs what it measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { TRANSCRIPT_SPACING } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-received-line.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-spacing-table";
  const VARIANT = "peer-lines";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const value = (id: string) => TRANSCRIPT_SPACING.find((row) => row.id === id)!.value;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript received line", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Line = {
    centre: number;
    text: string;
    fontSize: number;
    iconX: number | null;
    iconY: number | null;
  };
  type Measured = {
    glyph: number | null;
    received: Line | null;
    run: Line | null;
    sender: { text: string; height: number; top: number; bottom: number } | null;
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
      /** The centre of the glyph box of `element`'s first shown text line. */
      const textCentre = (element: Element) => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = [...range.getClientRects()].find((r) => r.width > 0 && r.height > 0);
          if (rect)
            return {
              centre: (rect.top + rect.bottom) / 2,
              size: parseFloat(getComputedStyle(node.parentElement).fontSize),
            };
        }
        return null;
      };
      const iconOf = (row: Element, selector: string) => {
        const icon = [...row.querySelectorAll(selector)].find(shown)?.getBoundingClientRect();
        return icon ? { x: (icon.left + icon.right) / 2, y: (icon.top + icon.bottom) / 2 } : null;
      };
      const line = (element: Element | null, textSelector: string, iconSelector: string): Line | null => {
        if (!element) return null;
        const text = element.querySelector(textSelector);
        const at = text && textCentre(text);
        if (!at) return null;
        const icon = iconOf(element, iconSelector);
        return {
          centre: at.centre,
          text: (element.textContent ?? "").replace(/\s+/g, " ").trim(),
          fontSize: at.size,
          iconX: icon?.x ?? null,
          iconY: icon?.y ?? null,
        };
      };
      const actions = [...document.querySelectorAll<HTMLElement>(".cv-turn-actions")].filter(shown)[0];
      const glyph = actions && [...actions.querySelectorAll("button svg")].find(shown)?.getBoundingClientRect();
      const receivedRow = [...document.querySelectorAll(".cv-received > .cv-disclosure__line")].find(shown) ?? null;
      const runRow = [...document.querySelectorAll("button[data-message-run]")].find(shown) ?? null;
      const tag = receivedRow?.querySelector(".cv-received__sender");
      const tagBox = tag?.querySelector(".cv-agent-tag")?.getBoundingClientRect();
      return {
        glyph: glyph ? (glyph.top + glyph.bottom) / 2 : null,
        received: line(receivedRow, ".cv-received__preview", ".cv-received__mark > *"),
        run: line(runRow, ".cv-tool__summary", ".cv-tool__icon > *"),
        sender:
          tag && tagBox
            ? {
                // The host's middle dot is its `::before`, which textContent leaves out.
                text: [...tag.querySelectorAll(".cv-received__from, .cv-received__host")]
                  .map((part) => (part.textContent ?? "").trim())
                  .join(" · "),
                height: tagBox.height,
                top: tagBox.top,
                bottom: tagBox.bottom,
              }
            : null,
      };
    });

  const measured = new Map<string, Measured>();
  const of = async (theme: (typeof THEMES)[number]) => {
    const known = measured.get(theme.file);
    if (known) return known;
    const page = await browser.newPage({
      viewport: { width: 1200, height: 1100 },
      deviceScaleFactor: 2,
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    try {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 1100, theme: theme.name, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      const result = await measure(page);
      if (process.env.CMUX_TRANSCRIPT_RECEIVED_LOG === "1")
        console.log(`TRANSCRIPT_RECEIVED ${theme.file} ${JSON.stringify(result)}`);
      measured.set(theme.file, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const theme of THEMES) {
    test(`finds the footer, the received line and the run's line (${theme.file})`, async () => {
      const got = await of(theme);
      expect(got.glyph).not.toBeNull();
      expect(got.received).not.toBeNull();
      expect(got.run).not.toBeNull();
      expect(got.sender).not.toBeNull();
    });
    test(`the received line sits the footer's room under it (${theme.file})`, async () => {
      const got = await of(theme);
      expect(Math.abs(got.received!.centre - got.glyph! - value("footer-to-next"))).toBeLessThanOrEqual(1);
    });
    test(`the received line and the run's line are one line apart (${theme.file})`, async () => {
      const got = await of(theme);
      expect(Math.abs(got.run!.centre - got.received!.centre - value("step-pitch"))).toBeLessThanOrEqual(0.5);
    });
    test(`the received line's words are the tool rows' size (${theme.file})`, async () => {
      const got = await of(theme);
      expect(got.received!.fontSize).toBe(got.run!.fontSize);
    });
    test(`the sender's mark and the run's icon share one column and centre (${theme.file})`, async () => {
      const got = await of(theme);
      expect(Math.abs(got.received!.iconX! - got.run!.iconX!)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(got.received!.iconY! - got.received!.centre)).toBeLessThanOrEqual(1);
    });
    test(`the sender is named once, its machine after it (${theme.file})`, async () => {
      const got = await of(theme);
      expect(got.sender!.text).toBe("merge-timeout · lane-vm-01");
      // Its message's "merge-timeout:" signature is out: the line names the sender once.
      expect(got.received!.text).toContain("lane-vm-01please deploy");
    });
    test(`the sender's tag stays inside its line, clear of the run's line (${theme.file})`, async () => {
      const got = await of(theme);
      expect(got.sender!.bottom).toBeLessThanOrEqual(got.run!.centre - 11 + 0.5);
    });
  }
});
