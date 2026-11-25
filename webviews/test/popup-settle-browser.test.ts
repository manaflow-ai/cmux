// cmux-web-test-timeout: 900
// l10n-allow-file: gallery browser assertions and capture filenames.
// Every popup holds still while the person only looks at it (src/ui/popupSettle.ts; Leo,
// 2026-11-22, on the new chat's Projects menu growing 315 -> 530 -> 315 px while open: "the
// shifting projects and sizing of stuff. and the shifting of the inner content. we need to
// prevent this once and for all").
//
// Part A: ui.popup-settle (src/ui/PopupSettle.gallery.tsx) opens each primitive and feeds it late
// data with no input; each must hold its box and its rows, except the named known shape (a short
// box that grows: its data must load before open) and data that follows typing.
// Part B: every gallery variant that ends with a real menu or popover open, sampled for ~40
// painted frames with no input: none may keep resizing on its own. A scene that does is fixed at
// its call site or listed in KNOWN_MOVING with its numbers and cause; the list only shrinks.
// Failures go to $FAST_CHECKS_OUT/popup-settle-report.json with a screenshot each.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { installPaintedFrames } from "./support/paintedFrames";
import {
  installPopupStill,
  POPUP_STILL_SELECTOR,
  popupBoxMoves,
  popupMoves,
  popupStillFor,
  type PopupRecord,
} from "./support/popupStill";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("popup-settle-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  /** POPUP_SETTLE_CLIPS=1: a video of each Part A scene, in $FAST_CHECKS_OUT/clips (for a pull request). */
  const clips = out && process.env.POPUP_SETTLE_CLIPS ? path.join(out, "clips") : undefined;
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const report: { part: string; scene: string; verdict: string; moves: string[]; frames: number }[] = [];

  /** Painted frames recorded after the last stage, so a late change has frames to show in. */
  const AFTER_STAGES = 12;
  /** Painted frames a swept popup is watched for with no input: about two thirds of a second. */
  const SWEEP_FRAMES = 40;

  type Scene = {
    entry: string;
    variant: string;
    /** The open popup (visible before sampling). */
    popup: string;
    /** What to record when it is not every shared popup (a popup with its own rule, an inline list). */
    record?: string;
    height?: number;
  };

  const FIXTURE = "ui.popup-settle";
  const fixture = (variant: string, popup: string): Scene => ({ entry: FIXTURE, variant, popup, height: 640 });
  const partA = {
    combobox: fixture("combobox", ".popup-settle-projects"),
    typed: fixture("combobox-typed", ".popup-settle-projects"),
    slots: fixture("menu-slots", ".popup-settle-slots"),
    loading: fixture("loading", ".popup-settle-loading"),
    context: fixture("context-late-row", ".popup-settle-context"),
    submenu: fixture("submenu-late", ".popup-settle-switch"),
    folders: fixture("folders", ".acpmux-folder-popover"),
  };

  const cc = "agent-pane.composer-context";
  const sweep: Scene[] = [
    ...[
      "folder-menu",
      "folder-menu-hover",
      "folder-menu-keyboard",
      "folder-long-list",
      "duplicate-worktrees",
      "repo-worktrees",
      "repo-worktrees-open",
      "lane-checkouts-open",
      "extra-folders-project",
    ].map((variant) => ({ entry: cc, variant, popup: ".acpmux-folder-popover" })),
    ...[
      ["environment-picker"],
      ["environment-picker-machines"],
      ["environment-picker-cloud-machines"],
      ["environment-picker-fleet", 760],
      ["machines-unavailable-open", 640],
      ["started-move-to-menu"],
    ].map(([variant, height]) => ({
      entry: cc,
      variant: variant as string,
      popup: ".acpmux-env-popover",
      height: height as number | undefined,
    })),
    ...[["computer-menu"], ["computer-menu-fleet", 760], ["computer-menu-cloud-machines"], ["computer-search"]].map(
      ([variant, height]) => ({
        entry: cc,
        variant: variant as string,
        popup: ".acpmux-location-menu",
        height: height as number | undefined,
      }),
    ),
    ...[
      "quick-menu",
      "quick-menu-many-profiles",
      "quick-menu-accounts",
      "quick-menu-rail",
      "relevant-many",
      "long-model-name",
      "search-grouped",
      "started-chat-quick-menu",
      "curated",
      "more-models",
    ].map((variant) => ({ entry: "agent-pane.model-picker", variant, popup: ".ui-popup", height: 560 })),
    ...[
      ["model-menu", ".acpmux-quick-menu"],
      ["claude-model-menu", ".acpmux-quick-menu"],
      ["claude-direct-accounts", ".acpmux-quick-menu", 580],
      ["effort-menu", ".acpmux-quick-effort-menu"],
      ["claude-effort-up", ".acpmux-quick-effort-menu"],
      ["permission-menu", ".acpmux-access-menu"],
      ["permission-managed", ".acpmux-access-menu"],
    ].map(([variant, popup, height]) => ({
      entry: "agent-pane.composer-pickers",
      variant: variant as string,
      popup: popup as string,
      height: (height as number | undefined) ?? 260,
    })),
    ...[
      "open-current",
      "open-path-titled",
      "open-app-icons",
      "lane-worktrees",
      "long-names",
      "long-no-actions",
      "no-matches",
    ].map((variant) => ({ entry: "agent-pane.project-chooser", variant, popup: ".acpmux-project-menu", height: 300 })),
    ...["overflowing", "mixed", "empty"].map((variant) => ({
      entry: "agent-pane.cloud-repository-picker",
      variant,
      popup: ".acpmux-cloud-repository-popover",
      height: 300,
    })),
    { entry: "agent-pane.options-menu", variant: "one-open", popup: ".acpmux-options-menu" },
    { entry: "agent-pane.options-menu", variant: "several-open", popup: ".acpmux-options-menu" },
    { entry: "agent-pane.open-in-menu", variant: "several-browsers", popup: ".ui-popup" },
    { entry: "agent-pane.retry-model-menu", variant: "open", popup: ".acpmux-retry-menu" },
    { entry: "agent-pane.saved-environment-panel", variant: "ssh-host-hover", popup: '.ui-popup[role="menu"]' },
    { entry: "agent-pane.saved-environment-panel", variant: "ssh-host-long-open", popup: '.ui-popup[role="menu"]' },
    { entry: "agent-pane.suggested-tasks", variant: "options-model-menu", popup: ".acpmux-task-menu", height: 420 },
    { entry: "ui.select", variant: "open", popup: ".ui-select-popup", height: 260 },
    { entry: "ui.select", variant: "overflowing", popup: ".ui-select-popup", height: 260 },
    ...["move-top-level", "move-submenu", "move-customized"].map((variant) => ({
      entry: "pages.settings-menus",
      variant,
      popup: "[data-picker]",
      record: "[data-picker], .ui-popup:not([data-popup-settle])",
      height: 1100,
    })),
    { entry: "pages.icon-picker", variant: "categories", popup: ".icon-category-menu" },
    { entry: "pages.icon-picker", variant: "actions", popup: ".icon-actions-menu" },
    { entry: "pages.icon-picker", variant: "tone-menu", popup: '.ui-popup[role="menu"]' },
    { entry: "agent-pane.header-controls-trio", variant: "trio-menu", popup: ".acpmux-chat-menu-popover" },
    { entry: "agent-pane.header-controls-trio", variant: "trio-new-menu", popup: ".acpmux-header-new-popover" },
    ...[
      ["menu-open", ".acpmux-chat-menu-popover"],
      ["menu-revoke-access", ".acpmux-chat-menu-popover"],
      ["menu-copy-submenu", ".acpmux-chat-menu-popover"],
      ["menu-cloud-machine-working", ".acpmux-chat-menu-popover"],
      ["customize-menu", '.ui-popup[role="menu"]'],
      ["pull-request-status", ".acpmux-pr-status"],
      ["pull-request-merge", ".acpmux-pr-status"],
      ["worktree-apply", ".acpmux-worktree-status"],
    ].map(([variant, popup]) => ({ entry: "agent-pane.header-tools", variant: variant!, popup: popup! })),
    // No popup: an inline picker whose list loads in place; its box is held to the same rule.
    ...["pending", "refreshing"].map((variant) => ({
      entry: "pages.home-channels.people-picker-loading",
      variant,
      popup: ".lg-picker",
      record: ".lg-picker",
      height: 280,
    })),
  ];

  /**
   * Swept scenes that still move with no input, each with what it measured and why. The list only
   * shrinks: a scene here that holds still fails until it is taken out.
   */
  const KNOWN_MOVING = new Map<string, string>([]);

  const key = (scene: Scene) => `${scene.entry} ${scene.variant}`;
  const WIDTH = 620;

  async function open(scene: Scene, { recordFromLoad }: { recordFromLoad: boolean }): Promise<Page> {
    const height = scene.height ?? 520;
    const page = await browser.newPage({
      viewport: { width: WIDTH, height },
      deviceScaleFactor: 1,
      reducedMotion: "reduce",
      ...(clips && recordFromLoad ? { recordVideo: { dir: clips, size: { width: WIDTH, height } } } : {}),
    });
    await installPaintedFrames(page);
    // The scene's own popup is recorded even where it keeps a rule of its own (`data-popup-settle`).
    const record = scene.record ?? `${scene.popup}, ${POPUP_STILL_SELECTOR}`;
    await installPopupStill(page, recordFromLoad ? { startAtLoad: record } : {});
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(scene.entry, { variant: scene.variant, colorScheme: "light", width: WIDTH, height })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.locator(scene.popup).first().waitFor({ state: "visible" });
    return page;
  }

  async function note(part: string, scene: Scene, page: Page, record: PopupRecord, moves: string[], verdict: string) {
    report.push({ part, scene: key(scene), verdict, moves, frames: record.frames.length });
    if (out && verdict !== "still")
      await page.screenshot({ path: path.join(out, `popup-settle-${scene.entry}-${scene.variant}.png`) });
  }

  /** Part A: open, wait for the last stage, record a few frames more. */
  async function staged(scene: Scene, input?: (page: Page) => Promise<void>) {
    const page = await open(scene, { recordFromLoad: true });
    try {
      const played = await page.evaluate(() =>
        JSON.stringify((window as unknown as { cmuxGalleryPlayReport: unknown }).cmuxGalleryPlayReport),
      );
      expect(playFailures(played)).toEqual([]);
      if (input) await input(page);
      await page.waitForFunction(
        () => document.querySelector(".popup-settle-stage")?.getAttribute("data-stage") === "done",
      );
      const record = await popupStillFor(page, AFTER_STAGES);
      const moves = popupMoves(record);
      await note("A", scene, page, record, moves, moves.length ? "moved" : "still");
      return { moves, record };
    } finally {
      await page.close();
      if (clips) await page.video()?.saveAs(path.join(clips, `${scene.variant}.webm`));
    }
  }

  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    const warmed = new Set<string>();
    for (const scene of [...Object.values(partA), ...sweep]) {
      if (warmed.has(scene.entry)) continue;
      warmed.add(scene.entry);
      await warmGalleryFrame(vite, scene.entry, { params: { variant: scene.variant } });
    }
    browser = await chromium.launch({ headless: true });
    if (out) await mkdir(out, { recursive: true });
  }, 600_000);
  afterAll(async () => {
    if (out) await writeFile(path.join(out, "popup-settle-report.json"), JSON.stringify(report, null, 2));
    await browser?.close();
    await vite?.close();
  });

  test("A(a): a popover's list goes 6 -> 14 -> 6 rows, its longest name doubled, with no input: still", async () => {
    expect((await staged(partA.combobox)).moves).toEqual([]);
  });

  test("A(b): menu rows gain an icon, a count and a longer label late, in kept slots: still", async () => {
    expect((await staged(partA.slots)).moves).toEqual([]);
  });

  test("A(c): known shape: a short Loading popover grows when its rows arrive, and the detector names it", async () => {
    const { moves } = await staged(partA.loading);
    const box = popupBoxMoves(moves);
    expect(box.length).toBeGreaterThan(0);
    expect(
      box.some((line) => /^popup \.popup-settle-loading grew [\d.]+ -> [\d.]+ px tall at frame \d+/.test(line)),
    ).toBe(true);
  });

  test("A(d): a context menu's row arrives late: still", async () => {
    expect((await staged(partA.context)).moves).toEqual([]);
  });

  test("A(e): a submenu's rows arrive late: still", async () => {
    expect((await staged(partA.submenu)).moves).toEqual([]);
  });

  test("A(f): the list changes right after a typed letter: allowed", async () => {
    const { record, moves } = await staged(partA.typed, async (page) => {
      await page.waitForFunction(
        () => document.querySelector(".popup-settle-stage")?.getAttribute("data-stage") === "open",
      );
      await page.keyboard.type("a");
    });
    expect(record.inputs.length).toBeGreaterThan(0);
    expect(moves).toEqual([]);
  });

  test("A(folders): the real folder menu, its list read again 5 -> 13 -> 5 and 15 -> 59 -> 15 worktrees: still", async () => {
    expect((await staged(partA.folders)).moves).toEqual([]);
  });

  for (const scene of sweep) {
    test(`B: ${key(scene)} holds still with no input`, async () => {
      const page = await open(scene, { recordFromLoad: true });
      try {
        const record = await popupStillFor(page, SWEEP_FRAMES);
        expect(record.frames.length).toBeGreaterThanOrEqual(SWEEP_FRAMES);
        const moves = popupMoves(record);
        const known = KNOWN_MOVING.get(key(scene));
        await note("B", scene, page, record, moves, moves.length ? (known ? "known-moving" : "moved") : "still");
        if (known && moves.length === 0) throw new Error(`${key(scene)} holds still now: take it out of KNOWN_MOVING`);
        if (!known) expect(moves).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
