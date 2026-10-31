// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// The chat's bottom stack (Leo, 2026-10-30: "the stupid fucking gap at the bottom plus the stupid
// right indent misalignemnt"; "you guys fucking removed the # prs thing entirely instead of just
// simply fucking doing it"; "BUT IF IT'S ONLY N PRS DON'T FUCKIGN TAKE THE ENTIRE ROW AND FUCKING
// BLANK IT OUT"):
// - every card over the composer (the running tray, open or folded to its "Running in background"
//   header, and the opened pull requests) takes the composer card's left and right x to 1px, and the
//   cards stand one stack gap (--acpmux-stack-gap) apart, the last of them on the composer card;
// - the folded "N PRs" count adds no row: the stack is as tall with it as with no pull requests,
//   with or without the tray, and the count is a content-sized control whose highlight is its own;
// - the stacked rows' trailing chevrons (the tray's header and each of its lines) share one x;
// - the count opens on the click, with no fade-in, to chips at the card's full width; no control
//   repeats on every row: a chip's own menu dismisses it, as Delete on a focused row does.
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
  dock: number;
  cards: Card[];
  gaps: number[];
  token: number | null;
  chips: { left: number; right: number }[];
  count: { where: string; width: number; content: number; text: string } | null;
  foot: number | null;
  chevrons: { name: string; x: number }[];
};

await requireBrowserLane("agent-pane-bottom-stack-edges.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.bottom-stack-styles";
  const out = process.env.CMUX_BOTTOM_STACK_CAPTURE ?? process.env.FAST_CHECKS_OUT;
  const WIDTHS = [1100, 760, 420];
  /** The selected look's states, held to every rule; the comparisons are measured for the record
   *  and held to the no-row rule where they claim it. */
  const CHECKED = ["collapsed", "no-tray", "expanded", "prs-open", "no-prs"];
  /** Each state with the count, and the same state without pull requests: the count adds no row. */
  const SAME_HEIGHT: [string, string][] = [
    ["collapsed", "no-prs"],
    ["no-tray", "no-tray-no-prs"],
    ["in-tray", "no-prs"],
    ["in-tray-no-tray", "no-tray-no-prs"],
  ];
  const VARIANTS = [
    "collapsed",
    "no-tray",
    "expanded",
    "prs-open",
    "no-prs",
    "no-tray-no-prs",
    "in-tray",
    "in-tray-no-tray",
    "above",
    "above-no-tray",
    "cards",
    "legacy-bars",
  ];
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
    const page = await browser!.newPage({ viewport: { width, height: 620 }, deviceScaleFactor: scale });
    await page.goto(url(variant, width, theme));
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    return page;
  }

  /** Runs in the page: the stack's painted cards top to bottom, the gaps between them, the count and
   *  the stacked chevrons. */
  function measure(): Geometry {
    const box = (el: Element) => el.getBoundingClientRect();
    const main = box(document.querySelector(".acpmux-main")!);
    const dock = document.querySelector(".acpmux-dock")!;
    const cards: Card[] = [];
    const add = (name: string, el: Element | null | undefined) => {
      if (!el) return;
      const r = box(el);
      if (r.width <= 0 || r.height <= 0) return;
      cards.push({ name, left: r.left, right: r.right, top: r.top, bottom: r.bottom });
    };
    add("prs", document.querySelector(".acpmux-dock > .acpmux-pr-stack"));
    for (const chip of document.querySelectorAll(".acpmux-dock .acpmux-pr-comparison__chip")) add("pr bar", chip);
    add("tray", document.querySelector(".acpmux-dock > .acpmux-running-tray"));
    add("composer", document.querySelector(".acpmux-composer-box"));
    cards.sort((a, b) => a.top - b.top);
    const gaps = cards.slice(1).map((card, index) => card.top - cards[index]!.bottom);
    let token: number | null = null;
    if (getComputedStyle(dock).getPropertyValue("--acpmux-stack-gap").trim()) {
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--acpmux-stack-gap)";
      dock.append(probe);
      token = probe.getBoundingClientRect().height;
      probe.remove();
    }
    const count = document.querySelector<HTMLElement>(".acpmux-pr-count");
    let content = 0;
    if (count) for (const child of count.children) content += box(child).width;
    const countStyle = count ? getComputedStyle(count) : undefined;
    const chips = [...document.querySelectorAll(".acpmux-pr-stack__list .acpmux-pr-stack__chip")].map((chip) => {
      const r = box(chip);
      return { left: r.left, right: r.right };
    });
    const foot = document.querySelector(".acpmux-composer-foot") ?? document.querySelector(".acpmux-composer-box");
    return {
      // The stack's height: from its first painted part to the pane's bottom edge.
      dock: Math.round((main.bottom - Math.min(...[...dock.children].map((part) => box(part).top))) * 10) / 10,
      cards,
      gaps,
      token,
      chips,
      count:
        count && countStyle
          ? {
              where: count.closest(".acpmux-composer-foot")
                ? "quiet row"
                : (count.closest(".acpmux-pr-count-host")?.getAttribute("data-placement") ?? "?"),
              width: box(count).width,
              content:
                content +
                parseFloat(countStyle.paddingLeft) +
                parseFloat(countStyle.paddingRight) +
                parseFloat(countStyle.columnGap || "0") * Math.max(0, count.children.length - 1),
              text: (count.textContent ?? "").trim(),
            }
          : null,
      foot: foot ? main.bottom - box(foot).bottom : null,
      // Every stacked row's trailing chevron by its glyph's center x: the tray's header and lines.
      chevrons: [
        ...[
          ...document.querySelectorAll(".acpmux-dock .acpmux-running-tray__head .acpmux-running-tray__status svg"),
        ].map((svg) => ({ name: "tray header", svg })),
        ...[...document.querySelectorAll(".acpmux-dock .acpmux-running-tray .acpmux-agent-line__chevron svg")].map(
          (svg, index) => ({ name: `tray line ${index + 1}`, svg }),
        ),
      ]
        .map(({ name, svg }) => ({ name, rect: svg.getBoundingClientRect() }))
        .filter(({ rect }) => rect.width > 0 && rect.height > 0)
        .map(({ name, rect }) => ({ name, x: (rect.left + rect.right) / 2 })),
    };
  }

  test("every bottom card shares the composer card's edges one stack gap apart, the count adds no row, and the stacked chevrons share one x", async () => {
    const offenders: string[] = [];
    for (const width of WIDTHS) {
      for (const variant of VARIANTS) {
        const page = await open(variant, width);
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
        if (variant !== "no-tray" && !geometry.cards.some((c) => c.name === "tray"))
          offenders.push(`${label}: no running tray`);
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
        if (variant !== "no-prs") {
          // The folded count: in the quiet row, content-sized, never a row of its own.
          const count = geometry.count;
          if (!count) offenders.push(`${label}: no "N PRs" count`);
          else {
            if (count.where !== "quiet row") offenders.push(`${label}: the count sits in ${count.where}`);
            if (count.text !== "2 PRs") offenders.push(`${label}: the count reads "${count.text}"`);
            if (Math.abs(count.width - count.content) > 1)
              offenders.push(
                `${label}: the count is ${count.width.toFixed(1)}px wide for ${count.content.toFixed(1)}px of content`,
              );
          }
          if (variant !== "prs-open" && geometry.cards.some((c) => c.name === "prs"))
            offenders.push(`${label}: a pull request row stands in the stack while folded`);
        }
        if (variant === "prs-open") {
          if (geometry.chips.length !== 2) offenders.push(`${label}: ${geometry.chips.length} chips shown, not 2`);
          for (const chip of geometry.chips)
            if (Math.abs(chip.left - card.left) > 1 || Math.abs(chip.right - card.right) > 1)
              offenders.push(
                `${label}: a chip spans ${chip.left.toFixed(1)}..${chip.right.toFixed(1)}, not the card's width`,
              );
        }
        const first = geometry.chevrons[0];
        for (const chevron of geometry.chevrons.slice(1))
          if (first && Math.abs(chevron.x - first.x) > 1)
            offenders.push(
              `${label}: ${chevron.name}'s chevron at x ${chevron.x.toFixed(1)}, ${first.name}'s at ${first.x.toFixed(1)}`,
            );
      }
      for (const [withCount, without] of SAME_HEIGHT) {
        const a = record[`${withCount} @${width}`]!;
        const b = record[`${without} @${width}`]!;
        if (Math.abs(a.dock - b.dock) > 0.5)
          offenders.push(
            `${withCount} @${width}: the stack is ${a.dock}px tall, ${without} ${b.dock}px: the count adds a row`,
          );
      }
    }
    expect(offenders).toEqual([]);
  });

  test('the "N PRs" count opens on the click, with no fade-in; its highlight is its own', async () => {
    const page = await open("collapsed", 760);
    try {
      const count = page.locator(".acpmux-composer-foot .acpmux-pr-count");
      expect(await count.count()).toBe(1);
      expect((await count.textContent())?.trim()).toBe("2 PRs");
      expect(await count.getAttribute("aria-expanded")).toBe("false");
      // Over the count, only the count lights: the quiet row around it keeps no fill.
      await count.hover();
      const lit = await count.evaluate((node) => ({
        own: getComputedStyle(node).backgroundColor,
        row: getComputedStyle(node.closest(".acpmux-composer-foot")!).backgroundColor,
      }));
      expect(lit.own).not.toBe("rgba(0, 0, 0, 0)");
      expect(lit.row).toBe("rgba(0, 0, 0, 0)");
      await count.click();
      // The same task as the click: the list is there, whole and opaque, with nothing running on it.
      const shown = await page.evaluate(() => {
        const list = document.querySelector(".acpmux-pr-stack__list");
        if (!list) return null;
        let animations = 0;
        let opacity = 1;
        for (let node: Element | null = list; node; node = node.parentElement) {
          opacity *= parseFloat(getComputedStyle(node).opacity);
          animations += node.getAnimations().filter((a) => a.playState === "running").length;
        }
        return { animations, opacity, height: list.getBoundingClientRect().height };
      });
      expect(shown).not.toBeNull();
      expect(shown!.animations).toBe(0);
      expect(shown!.opacity).toBe(1);
      expect(shown!.height).toBeGreaterThan(0);
      expect(await count.getAttribute("aria-expanded")).toBe("true");
      const links = page.locator(".acpmux-pr-stack__list a");
      expect(await links.count()).toBe(2);
      expect(await links.first().getAttribute("href")).toBe("https://github.com/acme/atlas-web/pull/129");
      // No control repeats on every row: a row is its link alone, at rest, hovered or focused.
      const rowControls = () =>
        page.evaluate(
          () =>
            document.querySelectorAll(
              ".acpmux-pr-stack__chip :is(button, [role='button']), .acpmux-pr-stack__chip a ~ a",
            ).length,
        );
      await page.mouse.move(5, 5);
      expect(await rowControls()).toBe(0);
      await links.first().hover();
      expect(await rowControls()).toBe(0);
      await links.first().focus();
      expect(await rowControls()).toBe(0);
      // Tab from the first row goes to the second row, not to a control of the first.
      await page.keyboard.press("Tab");
      expect(await page.evaluate(() => document.activeElement?.getAttribute("href") ?? null)).toBe(
        "https://github.com/acme/atlas-web/pull/128",
      );
      // A row's own menu dismisses it, and focus moves to the row now in its place; the count still
      // names both.
      // From the keyboard: Shift-F10 on the focused row opens the row's menu (a right-click's path),
      // and Return runs its one item.
      await page.mouse.move(5, 5);
      await links.first().focus();
      await page.keyboard.press("Shift+F10");
      const item = page.getByRole("menuitem", { name: "Dismiss pull request #129" });
      await item.waitFor({ timeout: 2_000 });
      expect(await page.getByRole("menuitem").count()).toBe(1);
      await page.keyboard.press("Enter");
      expect(await links.count()).toBe(1);
      expect((await count.textContent())?.trim()).toBe("2 PRs");
      await page.waitForFunction(() => document.activeElement?.matches(".acpmux-pr-stack__link") ?? false);
      // Delete on the focused last row dismisses it too. The count, with nothing left to open, is
      // disabled, so focus goes on to the composer's prompt, never to the page's body.
      await page.keyboard.press("Delete");
      expect(await page.locator(".acpmux-pr-stack__list a").count()).toBe(0);
      expect((await count.textContent())?.trim()).toBe("2 PRs");
      await page.waitForFunction(
        () =>
          document.activeElement !== document.body &&
          (document.activeElement?.matches('.acpmux-composer [contenteditable="true"], .acpmux-composer textarea') ??
            false),
        undefined,
        { timeout: 2_000 },
      );
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
        const page = await open(variant, 760, theme, 2);
        // The opened chips with the pointer on the first row: that row lights, with no control of its own.
        if (variant === "prs-open") await page.locator(".acpmux-pr-stack__link").first().hover();
        await page.screenshot({ path: path.join(out, "stills", `${variant}-${name}.png`) });
        await page.close();
      }
  });
});
