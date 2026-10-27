// What a New Tab opens appears in the frame it lands in (Leo 2026-10-22: no entry animations on the
// New Tab; exits are fine). Its menus, popovers, tooltips, hover cards and dialogs portal outside
// the page, so newtab/noEntry.css stops their opens under the root's `data-new-tab` mark. This draws
// each surface open on the pane's real stylesheet and reads what Chromium animates: nothing on the
// way in under the mark, while exits still fade, and without the mark the probe sees the opens.
// Skipped where Chromium is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { paneSheets } from "./support/paneSheets";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-no-entry-menus.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-no-entry-menus: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab no entry menus", () => test("chromium", () => {}));
    return;
  }
  const repo = path.resolve(import.meta.dir, "../..");
  // The pane's sheets, then noEntry.css where its import ships it (after them) if it is not listed.
  const NO_ENTRY_CSS = "webviews/src/agent-session/acpmux/newtab/noEntry.css";
  const sheets = paneSheets();
  const css = (sheets.includes(NO_ENTRY_CSS) ? sheets : [...sheets, NO_ENTRY_CSS])
    .map((file) =>
      readFileSync(path.join(repo, file), "utf8")
        .split("\n")
        .filter((line) => !line.startsWith("@import "))
        .join("\n"),
    )
    .join("\n");

  /// Each surface a New Tab opens, drawn as it is the frame it opens (a starting style where Base
  /// UI sets one, presence's `from`).
  const SURFACES: Record<string, string> = {
    "menu or select": `<div class="ui-popup ui-glass ui-menu" data-side="bottom">Menu</div>`,
    "context menu": `<div class="ui-popup ui-glass ui-context-menu">Open</div>`,
    "page popover": `<div class="ui-popup ui-glass ui-popover nt-popover" data-side="bottom">Popover</div>`,
    "chat filter menu": `<div class="ui-popup ui-glass ui-menu acpmux-file-menu-list" data-side="bottom">All</div>`,
    "composer picker menu": `<div class="acpmux-menu">Project</div>`,
    "slash menu": `<div class="acpmux-slash-menu">/</div>`,
    "model picker": `<div class="acpmux-mp">Model</div>`,
    "context ring popover": `<div class="acpmux-context-pop">Context</div>`,
    "access menu": `<div class="ui-popup ui-glass ui-menu acpmux-access-menu">Access</div>`,
    "effort slider": `<div class="ui-popup ui-glass ui-menu acpmux-effort-menu"><div class="acpmux-effort-track"></div></div>`,
    tooltip: `<div class="ui-tooltip ui-glass" data-starting-style>Tip</div>`,
    "hover card": `<div class="ui-tooltip ui-card ui-glass nt-hovercard" data-starting-style>Card</div>`,
    "title tooltip": `<div class="ui-title-tooltip ui-glass" data-starting-style>Title</div>`,
    dialog: `<div class="ui-backdrop" data-starting-style></div><div class="ui-dialog" data-starting-style>Dialog</div>`,
    "notice from an edge": `<div data-enter="top">Notice</div>`,
    "card with presence": `<div data-enter="bottom" data-presence="from">Card</div>`,
    "drop sheet": `<div class="acpmux-drop-overlay" data-phase="over"><div class="acpmux-drop-sheet"><div class="acpmux-drop-pill">Drop</div></div></div>`,
  };

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function open(reducedMotion: "reduce" | "no-preference", mark: boolean): Promise<Page> {
    const page = await browser.newPage();
    await page.emulateMedia({ reducedMotion });
    await page.setContent(
      `<!doctype html><html data-theme="dark"${mark ? " data-new-tab" : ""}><head><style>${css}</style></head><body><div id="root"></div></body></html>`,
    );
    return page;
  }

  /// The surfaces that animate as they open: each label with what runs (animation names, or the
  /// properties a transition moves).
  async function entrances(page: Page): Promise<Record<string, string[]>> {
    return page.evaluate(async (surfaces) => {
      // Reading each element's style starts a change's transitions from what was just drawn.
      const flushStyles = (root: HTMLElement) =>
        [...root.querySelectorAll<HTMLElement>("*")].map((element) => getComputedStyle(element).opacity).join();
      const root = document.getElementById("root")!;
      for (const [label, html] of Object.entries(surfaces)) {
        const host = document.createElement("div");
        host.dataset.fixture = label;
        host.innerHTML = html;
        root.append(host);
      }
      // The frame it mounts in, then the frame Base UI and presence clear their starting state.
      flushStyles(root);
      // raf-read: reads computed styles and the running animations, not layout; paint timing does not matter.
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      for (const element of root.querySelectorAll<HTMLElement>("[data-starting-style]"))
        element.removeAttribute("data-starting-style");
      for (const element of root.querySelectorAll<HTMLElement>('[data-presence="from"]'))
        element.dataset.presence = "shown";
      flushStyles(root);
      const found: Record<string, string[]> = {};
      for (const animation of document.getAnimations()) {
        const timing = animation.effect?.getComputedTiming();
        // Under Reduce Motion desktop.css cuts every animation to 0.01ms: that draws at once.
        if (!timing || Number(timing.activeDuration ?? 0) < 1) continue;
        const target = (animation.effect as KeyframeEffect | null)?.target as HTMLElement | null;
        const label = target?.closest<HTMLElement>("[data-fixture]")?.dataset.fixture;
        if (!label) continue;
        const what =
          "animationName" in animation
            ? (animation as CSSAnimation).animationName
            : (animation as CSSTransition).transitionProperty;
        (found[label] ??= []).push(what);
      }
      return found;
    }, SURFACES);
  }

  /// The surfaces that fade as they close, once each has opened.
  async function exits(page: Page): Promise<string[]> {
    return page.evaluate(async () => {
      // Reading each element's style starts a change's transitions from what was just drawn.
      const flushStyles = (root: HTMLElement) =>
        [...root.querySelectorAll<HTMLElement>("*")].map((element) => getComputedStyle(element).opacity).join();
      const root = document.getElementById("root")!;
      root.innerHTML = `
        <div data-fixture="menu" class="ui-popup ui-glass ui-menu">Menu</div>
        <div data-fixture="tooltip" class="ui-tooltip ui-glass">Tip</div>
        <div data-fixture="dialog" class="ui-dialog">Dialog</div>
        <div data-fixture="card with presence" data-enter="bottom" data-presence="shown">Card</div>`;
      flushStyles(root);
      // raf-read: reads computed styles and the running animations, not layout; paint timing does not matter.
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      for (const element of root.querySelectorAll<HTMLElement>("[data-fixture]")) {
        if (element.dataset.presence) element.dataset.presence = "leaving";
        else element.setAttribute("data-ending-style", "");
      }
      flushStyles(root);
      const fading = new Set<string>();
      for (const animation of document.getAnimations()) {
        const target = (animation.effect as KeyframeEffect | null)?.target as HTMLElement | null;
        if (Number(animation.effect?.getComputedTiming().activeDuration ?? 0) > 0 && target?.dataset.fixture)
          fading.add(target.dataset.fixture);
      }
      return [...fading].sort();
    });
  }

  for (const reducedMotion of ["no-preference", "reduce"] as const) {
    test(`on a New Tab, every surface it opens appears at once (${reducedMotion})`, async () => {
      const page = await open(reducedMotion, true);
      try {
        expect(await entrances(page)).toEqual({});
      } finally {
        await page.close();
      }
    });
  }

  /// A file dropped on the page: the overlay mounted in `over` turns `landing` (attachmentIntake.tsx
  /// landDropOverlay), and the sheet flies into the composer. What runs on the sheet and the pill
  /// once it lands, by animation name.
  async function landing(page: Page): Promise<{ sheet: string[]; pill: string[] }> {
    return page.evaluate(async () => {
      const root = document.getElementById("root")!;
      root.innerHTML = `<div class="acpmux-drop-overlay" data-phase="over"><div class="acpmux-drop-sheet"><div class="acpmux-drop-pill"><span class="acpmux-drop-mark"></span></div></div></div>`;
      const overlay = root.querySelector<HTMLElement>(".acpmux-drop-overlay")!;
      [...root.querySelectorAll<HTMLElement>("*")].map((element) => getComputedStyle(element).animationName).join();
      // raf-read: reads the running animations, not layout; paint timing does not matter.
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      overlay.dataset.phase = "landing";
      [...root.querySelectorAll<HTMLElement>("*")].map((element) => getComputedStyle(element).animationName).join();
      const running = (selector: string) =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              (animation.effect as KeyframeEffect | null)?.target === root.querySelector(selector) &&
              Number(animation.effect?.getComputedTiming().activeDuration ?? 0) >= 1,
          )
          .map((animation) => (animation as CSSAnimation).animationName ?? "transition")
          .sort();
      return { sheet: running(".acpmux-drop-sheet"), pill: running(".acpmux-drop-pill") };
    });
  }

  // The sheet's exit is the page's own: the same with the New Tab's mark as without it (under
  // Reduce Motion desktop.css cuts it to 0.01ms in either case).
  for (const reducedMotion of ["no-preference", "reduce"] as const) {
    test(`on a New Tab, a dropped file's pill does not enter again as the sheet lands (${reducedMotion})`, async () => {
      const marked = await open(reducedMotion, true);
      const unmarked = await open(reducedMotion, false);
      try {
        const page = await landing(unmarked);
        if (reducedMotion === "no-preference") expect(page.sheet).toEqual(["acpmux-drop-land"]);
        expect(await landing(marked)).toEqual({ sheet: page.sheet, pill: [] });
      } finally {
        await marked.close();
        await unmarked.close();
      }
    });
  }

  test("on a New Tab, menus, tooltips, dialogs and cards still fade as they close", async () => {
    const page = await open("no-preference", true);
    try {
      expect(await exits(page)).toEqual(["card with presence", "dialog", "menu", "tooltip"]);
    } finally {
      await page.close();
    }
  });

  test("the probe sees the opens a page without the mark plays", async () => {
    const page = await open("no-preference", false);
    try {
      const seen = Object.keys(await entrances(page));
      // Menus and popovers open in one frame on every page (test/popover-instant-open.test.ts).
      for (const label of ["tooltip", "hover card", "dialog", "notice from an edge", "card with presence"])
        expect(seen).toContain(label);
    } finally {
      await page.close();
    }
  });
});
