// cmux-web-test-timeout: 600
// l10n-allow-file: test labels, not shipped UI.
// The chat's bottom stack shares one left and one right edge (Leo, 2026-10-30: "the stupid fucking
// gap at the bottom plus the stupid right indent misalignemnt"). Every card over the composer (the
// chat's pull requests, the running tray, whether open or folded to its "Running in background"
// header) takes the composer card's left and right x to 1px, the cards stand one stack gap
// (--acpmux-stack-gap) apart, and the last of them stands that same gap above the composer card,
// never more. The chat's pull requests keep a one-line "N PRs" row with a disclosure (Leo: "you guys
// fucking removed the # prs thing entirely instead of just simply fucking doing it"); it opens on
// the click, with no fade-in, to chips at the card's full width.
//
// Real gallery frames (agent-pane.bottom-stack-styles) at a wide, a normal and a narrow pane.
// With FAST_CHECKS_OUT (cmux-ci) or CMUX_BOTTOM_STACK_CAPTURE set, the measurements are written as
// geometry.json there, with 2x light and dark stills of every variant.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Card = { name: string; left: number; right: number; top: number; bottom: number };
type Geometry = {
  pane: { left: number; right: number; bottom: number };
  cards: Card[];
  gaps: number[];
  token: number | null;
  chips: { left: number; right: number }[];
  prRow: { lines: number; text: string; expanded: string | null } | null;
  foot: number | null;
  trail: Record<string, number | null>;
};

await requireBrowserLane("agent-pane-bottom-stack-edges.test.ts", async () => {
  setDefaultTimeout(540_000);
  const ENTRY = "agent-pane.bottom-stack-styles";
  const out = process.env.CMUX_BOTTOM_STACK_CAPTURE ?? process.env.FAST_CHECKS_OUT;
  const WIDTHS = [1100, 760, 420];
  /** The variants every pane must keep on one edge; `legacy-bars` (the bars before cmux#26082,
   *  a gallery comparison only) and the style comparisons are measured for the record. */
  const CHECKED = ["collapsed", "expanded", "prs-open"];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const record: Record<string, Geometry> = {};

  beforeAll(async () => {
    if (out) mkdirSync(path.join(out, "stills"), { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    if (out) writeFileSync(path.join(out, "geometry.json"), JSON.stringify(record, null, 2));
    console.log(`bottom-stack geometry: ${JSON.stringify(record)}`);
    await browser?.close();
    await vite?.close();
  });

  const url = (variant: string, width: number, theme?: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, {
      variant,
      width,
      theme,
    })}`;

  async function open(variant: string, width: number, theme?: string, scale = 1): Promise<Page> {
    const page = await browser!.newPage({
      viewport: { width, height: 620 },
      deviceScaleFactor: scale,
    });
    await page.goto(url(variant, width, theme));
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    return page;
  }

  /** Runs in the page: every painted card of the stack, top to bottom, and the gaps between them. */
  function measure(): Geometry {
    const box = (el: Element) => el.getBoundingClientRect();
    const main = document.querySelector(".acpmux-main")!.getBoundingClientRect();
    const dock = document.querySelector(".acpmux-dock");
    const cards: Card[] = [];
    const add = (name: string, el: Element | null | undefined) => {
      if (!el) return;
      const r = box(el);
      if (r.width <= 0 || r.height <= 0) return;
      cards.push({ name, left: r.left, right: r.right, top: r.top, bottom: r.bottom });
    };
    // The restored pull request row (or, in the legacy comparison, each bar), the tray, the card.
    add("prs", document.querySelector(".acpmux-dock > .acpmux-pr-stack"));
    for (const chip of document.querySelectorAll(".acpmux-dock .acpmux-pr-comparison__chip")) add("pr bar", chip);
    add("tray", document.querySelector(".acpmux-dock > .acpmux-running-tray"));
    add("composer", document.querySelector(".acpmux-composer-box"));
    cards.sort((a, b) => a.top - b.top);
    const gaps = cards.slice(1).map((card, index) => card.top - cards[index]!.bottom);
    const raw = dock ? getComputedStyle(dock).getPropertyValue("--acpmux-stack-gap").trim() : "";
    let token: number | null = null;
    if (raw && dock) {
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--acpmux-stack-gap)";
      dock.append(probe);
      token = probe.getBoundingClientRect().height;
      probe.remove();
    }
    const row = document.querySelector(".acpmux-pr-stack__row");
    const lineHeight = row ? parseFloat(getComputedStyle(row).lineHeight) || 18 : 0;
    const chips = [...document.querySelectorAll(".acpmux-pr-stack__list .acpmux-pr-stack__chip")].map((chip) => {
      const r = box(chip);
      return { left: r.left, right: r.right };
    });
    const foot = document.querySelector(".acpmux-composer-foot") ?? document.querySelector(".acpmux-composer-box");
    return {
      pane: { left: main.left, right: main.right, bottom: main.bottom },
      cards,
      gaps,
      token,
      chips,
      prRow: row
        ? {
            lines: Math.round(
              (row.querySelector(".acpmux-pr-stack__count") ?? row).getBoundingClientRect().height / lineHeight,
            ),
            text: (row.textContent ?? "").trim(),
            expanded: row.getAttribute("aria-expanded"),
          }
        : null,
      foot: foot ? main.bottom - foot.getBoundingClientRect().bottom : null,
      // Where each part's last trailing mark centers, from the composer card's right edge (for the
      // record: the tray header's chevron column is cmux#27930's).
      trail: (() => {
        const right = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect().right ?? 0;
        const center = (selector: string) => {
          const icon = document.querySelector(selector);
          if (!icon) return null;
          const r = icon.getBoundingClientRect();
          return Math.round((right - (r.left + r.right) / 2) * 10) / 10;
        };
        return {
          prs: center(".acpmux-pr-stack__status svg"),
          tray: center(".acpmux-running-tray__head .acpmux-running-tray__status svg"),
          composer: center(".acpmux-composer-box button:last-of-type svg"),
        };
      })(),
    };
  }

  const VARIANTS = ["collapsed", "expanded", "prs-open", "cards", "strip", "legacy-bars"];

  test("every bottom card shares the composer card's left and right edge, one stack gap apart", async () => {
    const offenders: string[] = [];
    for (const width of WIDTHS)
      for (const variant of VARIANTS) {
        let page: Page;
        try {
          page = await open(variant, width);
        } catch (error) {
          // A variant this tree's gallery does not have (a comparison added with the fix).
          if (CHECKED.includes(variant))
            offenders.push(`${variant} @${width}: did not load (${String(error).split("\n")[0]})`);
          continue;
        }
        const geometry = await page.evaluate(measure);
        await page.close();
        const label = `${variant} @${width}`;
        record[label] = geometry;
        if (!CHECKED.includes(variant)) continue;
        const card = geometry.cards.find((c) => c.name === "composer");
        if (!card) {
          offenders.push(`${label}: no composer card`);
          continue;
        }
        if (!geometry.cards.some((c) => c.name === "prs")) offenders.push(`${label}: no "N PRs" row in the stack`);
        if (!geometry.cards.some((c) => c.name === "tray")) offenders.push(`${label}: no running tray`);
        for (const c of geometry.cards) {
          if (c.name === "composer") continue;
          const left = c.left - card.left;
          const right = c.right - card.right;
          if (Math.abs(left) > 1 || Math.abs(right) > 1)
            offenders.push(
              `${label}: ${c.name} left ${left.toFixed(1)}px, right ${right.toFixed(1)}px off the composer card`,
            );
        }
        if (geometry.token === null) offenders.push(`${label}: the dock has no --acpmux-stack-gap`);
        else
          geometry.gaps.forEach((gap, index) => {
            if (Math.abs(gap - geometry.token!) > 0.5)
              offenders.push(
                `${label}: ${geometry.cards[index]!.name} to ${geometry.cards[index + 1]!.name} gap ${gap.toFixed(1)}px, not ${geometry.token}px`,
              );
          });
        if (geometry.prRow && geometry.prRow.lines !== 1)
          offenders.push(`${label}: the PR row takes ${geometry.prRow.lines} lines`);
        if (variant === "prs-open") {
          if (geometry.chips.length !== 2) offenders.push(`${label}: ${geometry.chips.length} chips shown, not 2`);
          for (const chip of geometry.chips)
            if (Math.abs(chip.left - card.left) > 1 || Math.abs(chip.right - card.right) > 1)
              offenders.push(
                `${label}: a chip spans ${chip.left.toFixed(1)}..${chip.right.toFixed(1)}, not the card's width`,
              );
        }
      }
    expect(offenders).toEqual([]);
  });

  test('the "N PRs" disclosure opens on the click, with no fade-in', async () => {
    const page = await open("collapsed", 760);
    try {
      const row = page.locator(".acpmux-pr-stack__row");
      expect(await row.count()).toBe(1);
      expect((await row.textContent())?.trim()).toBe("2 PRs");
      expect(await row.getAttribute("aria-expanded")).toBe("false");
      await row.click();
      // The same task as the click: the list is there, whole and opaque, with nothing running on it.
      const shown = await page.evaluate(() => {
        const list = document.querySelector(".acpmux-pr-stack__list");
        if (!list) return null;
        const animations = list.getAnimations({ subtree: true }).filter((a) => a.playState === "running");
        let opacity = 1;
        for (let node: Element | null = list; node; node = node.parentElement)
          opacity *= parseFloat(getComputedStyle(node).opacity);
        return {
          animations: animations.length,
          opacity,
          height: list.getBoundingClientRect().height,
        };
      });
      expect(shown).not.toBeNull();
      expect(shown!.animations).toBe(0);
      expect(shown!.opacity).toBe(1);
      expect(shown!.height).toBeGreaterThan(0);
      expect(await row.getAttribute("aria-expanded")).toBe("true");
      const links = page.locator(".acpmux-pr-stack__list a");
      expect(await links.count()).toBe(2);
      expect(await links.first().getAttribute("href")).toBe("https://github.com/acme/atlas-web/pull/129");
      // The per-message pills (cmux#26082) stay where they are.
      expect(await page.locator(".acpmux-scroll .acpmux-pr-dock").count()).toBeGreaterThan(0);
    } finally {
      await page.close();
    }
  });

  test("stills", async () => {
    if (!out) return;
    for (const variant of VARIANTS)
      for (const [theme, name] of [
        ["Apple System Colors", "dark"],
        ["Apple System Colors Light", "light"],
      ] as const) {
        let page: Page;
        try {
          page = await open(variant, 760, theme, 2);
        } catch {
          continue;
        }
        await page.screenshot({ path: path.join(out, "stills", `${variant}-${name}.png`) });
        await page.close();
      }
  });
});
