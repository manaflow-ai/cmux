// The clickable agent-session chip on a transcript row (Leo, 2026-11-01: "this highlight is both
// not aligned with the icon vertically and too small and also not prominent enough because the
// whole line gets highlighted and it's not obvious that clicking on this will be a new thing"), in
// a real layout (test/browser/session-chip.harness.tsx): on a received message's line and on a
// sent message's row, the chip's centre is the row icon's centre, it has real padding around its
// name, it reads as a way to another chat (its own tint, no arrow glyph), and pointing at it lights the chip alone:
// the line's background and text keep their tone. design/chat-transcript.md "Session link chip".
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// SESSION_CHIP_CAPTURE=1 prints each state's 2x crop as base64 PNG, for a look from a fleet step.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-chip-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/session-chip.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const capture = async (page: Page, name: string) => {
    if (process.env.SESSION_CHIP_CAPTURE !== "1") return;
    const png = await page.screenshot({ clip: { x: 0, y: 0, width: 700, height: 190 } });
    console.log(`SESSION_CHIP_CAPTURE ${name} ${png.toString("base64")}`);
  };

  // Each row: where its chip is, the line that must not light, and its icon's glyph.
  const ROWS = {
    received: {
      chip: '[data-chip-row="received"] button.cv-agent-tag',
      line: '[data-chip-row="received"] .cv-disclosure__line',
      // The glyph itself, not its wrapper's line box.
      icon: '[data-chip-row="received"] .cv-received__mark :is(svg, img)',
    },
    sent: {
      chip: '[data-chip-row="sent"] button.cv-agent-tag',
      line: '[data-chip-row="sent"] .cv-tool',
      icon: '[data-chip-row="sent"] .cv-tool__icon svg',
    },
  } as const;

  // Every running transition (a colour fading in after load or a hover) ends before a state is read;
  // a loop that never ends (a spinner) is not waited on.
  const settled = (page: Page) =>
    page.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          .filter((animation) => animation.effect?.getComputedTiming().iterations !== Infinity)
          .map((animation) => animation.finished.catch(() => undefined)),
      ),
    );

  const measure = async (page: Page, row: (typeof ROWS)[keyof typeof ROWS]) => {
    await settled(page);
    return page.evaluate((row) => {
      const chip = document.querySelector<HTMLElement>(row.chip)!;
      const line = document.querySelector<HTMLElement>(row.line)!;
      const icon = document.querySelector<Element>(row.icon)!;
      const label = chip.querySelector(".cv-agent-tag__label")!;
      // Any glyph drawn in the chip (the ↗ it once carried): there is none.
      const cue = chip.querySelector<SVGElement>("svg");
      const c = chip.getBoundingClientRect();
      const i = icon.getBoundingClientRect();
      const l = label.getBoundingClientRect();
      // A colour as painted (rgba over a 1px canvas): oklab and srgb spellings of one colour agree.
      const paint = (color: string) => {
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 1;
        const context = canvas.getContext("2d")!;
        context.fillStyle = color;
        context.fillRect(0, 0, 1, 1);
        return [...context.getImageData(0, 0, 1, 1).data].join(",");
      };
      const lineStyle = getComputedStyle(line);
      const chipStyle = getComputedStyle(chip);
      return {
        chipCentre: c.top + c.height / 2,
        iconCentre: i.top + i.height / 2,
        chipHeight: c.height,
        chipWidth: c.width,
        lineWidth: line.getBoundingClientRect().width,
        insetStart: l.left - c.left,
        insetEnd: c.right - l.right,
        cue: chip.querySelectorAll("svg").length + (/↗/.test(chip.textContent ?? "") ? 1 : 0),
        labelCut: label.scrollWidth > label.clientWidth + 0.5,
        chipColor: paint(chipStyle.color),
        chipBackground: paint(chipStyle.backgroundColor),
        lineColor: paint(lineStyle.color),
        lineBackground: paint(lineStyle.backgroundColor),
        preview: paint(
          getComputedStyle(line.querySelector(".cv-received__preview, .cv-agentmsg__preview") ?? line).color,
        ),
      };
    }, row);
  };

  for (const theme of ["dark", "light"] as const)
    for (const [kind, row] of Object.entries(ROWS)) {
      test(`${theme} ${kind}: the session chip sits on the icon's centre line, padded, a link, lit alone`, async () => {
        const page = await browser.newPage({ viewport: { width: 700, height: 320 }, deviceScaleFactor: 2 });
        try {
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          const port = (vite.httpServer!.address() as { port: number }).port;
          // No transitions: each state is measured as it settles, with no wait.
          await page.emulateMedia({ reducedMotion: "reduce" });
          await page.goto(`http://127.0.0.1:${port}/test/browser/session-chip.html?theme=${theme}`);
          await page.locator(row.chip).waitFor();
          await page.evaluate(() => document.fonts.ready);
          await page.mouse.move(690, 310);
          await capture(page, `${theme}-${kind}-rest`);
          const rest = await measure(page, row);

          // Centred on the icon's centre line, to half a device pixel.
          expect(Math.abs(rest.chipCentre - rest.iconCentre)).toBeLessThanOrEqual(0.5);
          // Sized to its name with real padding, not a tight strip.
          expect(rest.chipHeight).toBeGreaterThanOrEqual(22);
          expect(rest.insetStart).toBeGreaterThanOrEqual(4);
          expect(rest.insetEnd).toBeGreaterThanOrEqual(4);
          expect(rest.chipWidth).toBeLessThan(rest.lineWidth * 0.6);
          // The whole name shows when the line has room for it: never cut beside an empty gap.
          expect(rest.labelCut).toBe(false);
          // A link: its own colour, apart from the line's words, and no arrow glyph (Leo, 2026-11-01:
          // "nobody asked for that up right arrow").
          expect(rest.chipColor).not.toBe(rest.lineColor);
          expect(rest.cue).toBe(0);

          // Pointing at the chip lights it alone: the line's plate and tone stay as at rest.
          await page.locator(row.chip).hover();
          await capture(page, `${theme}-${kind}-hover-chip`);
          const hover = await measure(page, row);
          expect(hover.chipBackground).not.toBe(rest.chipBackground);
          expect(hover.cue).toBe(0);
          expect(hover.lineBackground).toBe(rest.lineBackground);
          expect(hover.lineColor).toBe(rest.lineColor);
          expect(hover.preview).toBe(rest.preview);
          expect(Math.abs(hover.chipCentre - hover.iconCentre)).toBeLessThanOrEqual(0.5);

          // Clicking it opens that chat and still lights nothing of the line.
          await page.locator(row.chip).click();
          const clicked = await measure(page, row);
          expect(clicked.lineBackground).toBe(rest.lineBackground);
          expect(clicked.lineColor).toBe(rest.lineColor);
          expect(await page.evaluate(() => (window as unknown as { opened: string[] }).opened.length)).toBe(1);
          expect(errors).toEqual([]);
        } finally {
          await page.close();
        }
      });
    }

  // Leo, 2026-11-01: "dont do blue by default, theme it". The chip's text, tint and ring are the
  // theme's own text colour (--cv-text, from the host's --agent-text) at rest and under the pointer,
  // in light, dark and a non-default theme whose own blue is set (Catppuccin Mocha): never the link
  // blue. design/chat-transcript.md "Session link chip".
  const CHIPS = {
    received: ROWS.received.chip,
    sent: ROWS.sent.chip,
    reply: '[data-chip-row="reply"] .acpmux-started-chip',
  } as const;
  const chipColours = async (page: Page, selector: string) => {
    await settled(page);
    return page.evaluate((selector) => {
      const chip = document.querySelector<HTMLElement>(selector)!;
      // The theme's text token as this chip's scope resolves it.
      const probe = document.createElement("span");
      probe.style.color = "var(--cv-text)";
      chip.parentElement!.append(probe);
      // A computed colour as [r, g, b] in 0-255 and its alpha. Chromium gives rgb(), color(srgb ...)
      // (any srgb color-mix) or, for an oklab mix such as the link blue, oklab(); the last is read
      // back off a 1px canvas, which is exact for an opaque colour.
      const parse = (value: string) => {
        const colour = /^((?:rgba?|color|oklab|oklch|lab|lch)\([^)]*\))/.exec(value.trim())?.[1];
        if (!colour) return null;
        const match = /^(rgba?|color)\((?:srgb\s+)?([^)]*)\)$/.exec(colour);
        if (match) {
          const parts = match[2]!
            .split(/[\s,/]+/)
            .filter(Boolean)
            .map(Number);
          const scale = match[1] === "color" ? 255 : 1;
          return { rgb: parts.slice(0, 3).map((part) => part * scale), alpha: parts[3] ?? 1 };
        }
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 1;
        const context = canvas.getContext("2d")!;
        context.fillStyle = colour;
        context.fillRect(0, 0, 1, 1);
        const [r, g, bl, a] = context.getImageData(0, 0, 1, 1).data;
        return { rgb: [r!, g!, bl!], alpha: a! / 255 };
      };
      const token = getComputedStyle(probe).color;
      const style = getComputedStyle(chip);
      const result = {
        token: parse(token),
        text: parse(style.color),
        tint: parse(style.backgroundColor),
        ring: style.boxShadow === "none" ? null : parse(style.boxShadow),
      };
      probe.remove();
      return result;
    }, selector);
  };
  const sameRgb = (a: { rgb: number[] } | null, b: { rgb: number[] } | null) => {
    expect(a).not.toBeNull();
    expect(b).not.toBeNull();
    for (const [index, channel] of a!.rgb.entries()) expect(Math.abs(channel - b!.rgb[index]!)).toBeLessThanOrEqual(1);
  };

  for (const theme of ["dark", "light", "mocha"] as const)
    for (const [kind, selector] of Object.entries(CHIPS)) {
      test(`${theme} ${kind}: the session chip takes the theme's text colour, never the link blue`, async () => {
        const page = await browser.newPage({ viewport: { width: 700, height: 320 }, deviceScaleFactor: 2 });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.emulateMedia({ reducedMotion: "reduce" });
          await page.goto(`http://127.0.0.1:${port}/test/browser/session-chip.html?theme=${theme}`);
          await page.locator(selector).waitFor();
          await page.mouse.move(690, 310);
          const rest = await chipColours(page, selector);
          // Its words are the theme's text, its tint and ring a wash of that same colour.
          sameRgb(rest.text, rest.token);
          expect(rest.text!.alpha).toBe(1);
          sameRgb(rest.tint, rest.token);
          expect(rest.tint!.alpha).toBeGreaterThan(0);
          if (rest.ring) sameRgb(rest.ring, rest.token);

          // Under the pointer it lifts with a stronger wash of the same token, still no blue.
          await page.locator(selector).hover();
          const hover = await chipColours(page, selector);
          sameRgb(hover.text, hover.token);
          sameRgb(hover.tint, hover.token);
          expect(hover.tint!.alpha).toBeGreaterThan(rest.tint!.alpha);
          if (hover.ring) sameRgb(hover.ring, hover.token);
        } finally {
          await page.close();
        }
      });
    }

  test("a reply's started-chat chip carries no arrow glyph", async () => {
    const page = await browser.newPage({ viewport: { width: 700, height: 320 }, deviceScaleFactor: 2 });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(`http://127.0.0.1:${port}/test/browser/session-chip.html?theme=dark`);
      const chip = page.locator('[data-chip-row="reply"] .acpmux-started-chip');
      await chip.waitFor();
      expect(await chip.locator("svg").count()).toBe(0);
      expect(await chip.textContent()).not.toContain("↗");
      await chip.hover();
      await settled(page);
      await capture(page, "dark-reply-hover-chip");
    } finally {
      await page.close();
    }
  });
});
