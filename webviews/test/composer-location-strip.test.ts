// cmux-web-test-timeout: 240
// The composer's location strip (hq#1957 composer location strip). Leo: the folder and host row
// ("Choose folder ⌄ · cosmic-gray ⌄") sat inside the card as a second row under the controls,
// wasting space. It is now text a few px over the card, in the chat composer as in the New Tab's
// (#21133; Leo 2026-10-25, Cmd-I's new chat "a different style from everything else"):
//   - the strip stands a few px above the card's top edge, and it stays within the card's sides;
//   - the card holds one controls row and no location row;
//   - the strip is as tall with no project, with one and while the host loads;
//   - only a new chat has the strip, before its first send: a started chat's card stands alone,
//     with nothing drawn and no gap above it, and its queued prompts sit on the card;
//   - while the session has not reported effort and access, no skeleton or placeholder draws, and
//     the controls keep their places when the values arrive (the effort is the model button's own
//     label since Leo 2026-10-20, not a chip of its own);
//   - the folder popover filters with its search field and tells duplicate names apart;
//   - the folder popover folds a repository's worktrees under one row (Austin 2026-10-20: each cmux
//     worktree listed as a project of its own), opened by → or the count and found by branch;
//   - design panel (compact composer): the strip's first and last marks line up with the prompt's
//     edges, with no gap where it stands inside the card's corner; no "·" floats between folder
//     and computer; in a narrow pane the folder cuts in the middle ("atl…web"), the computer shows
//     its icon alone (named by its tooltip and label) and the branch keeps its name.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rect = { left: number; right: number; top: number; bottom: number; height: number };

await requireBrowserLane("composer-location-strip.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-location-strip: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer location strip", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  // Each page loads its entry file alone (`entryPath`, src/gallery/registry.ts). Without it every
  // page loaded all ~150 gallery entries (about 2,300 modules) and the warm-up transformed them all
  // first: beside the other dev server files on a CI runner the file was killed at its 120 s limit
  // after eight of its cases (job 119080446280), with nothing stuck.
  const ENTRY_PATHS: Record<string, string> = {
    "agent-pane.composer-strip": "src/agent-session/acpmux/composerStrip.gallery.ts",
    "agent-pane.composer-context": "src/agent-session/acpmux/ComposerContext.gallery.tsx",
    "agent-pane.project-chooser": "src/agent-session/acpmux/ProjectChooser.gallery.tsx",
    "agent-pane.new-tab": "src/agent-session/acpmux/newtab/NewTabScreen.gallery.ts",
  };
  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&entryPath=${ENTRY_PATHS[entry]}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    // The entry files and the hosts they mount (the strip and the New Tab in frame/agentPane.ts,
    // which imports acpmux/main; the folder popover in frame/component.tsx), not the frame: its
    // registry names every entry. Module URLs carry the config's base, /gallery/; a path outside it
    // is a 404 that warms nothing, so that fails here.
    for (const file of [
      ...Object.values(ENTRY_PATHS),
      "src/gallery/frame/agentPane.ts",
      "src/gallery/frame/component.tsx",
    ])
      if ((await warmViteServer(vite, `/gallery/${file}`)) === 0)
        throw new Error(`warmViteServer: ${file} imports nothing; is it served?`);
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 720, height: 400 } });
    await warm.goto(stageURL("agent-pane.composer-strip", "project"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (
    entry: string,
    variant: string,
    width: number,
    init?: () => void,
    height = 560,
  ): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height } });
    if (init) await page.addInitScript(init);
    await page.goto(stageURL(entry, variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Runs in the page: the strip against the card it heads. */
  function measureStrip(card: string) {
    const rect = (element: Element | null): Rect | null => {
      if (!element) return null;
      const { left, right, top, bottom, height } = element.getBoundingClientRect();
      return { left, right, top, bottom, height };
    };
    const box = document.querySelector(card);
    return {
      strip: rect(document.querySelector(".acpmux-composer-strip")),
      card: rect(box),
      controlRows: box?.querySelectorAll(".acpmux-composer-bar, .nt-pickers").length ?? -1,
      locationInCard: box?.querySelectorAll(".acpmux-composer-context, .acpmux-location-picker").length ?? -1,
      stripFolder: document.querySelector(".acpmux-composer-strip .acpmux-location-picker") !== null,
      queue: rect(document.querySelector(".acpmux-composer-queue")),
      form: rect(document.querySelector(".acpmux-composer")),
      formPaddingTop: (() => {
        const form = document.querySelector(".acpmux-composer");
        return form ? parseFloat(getComputedStyle(form).paddingTop) || 0 : 0;
      })(),
    };
  }

  const surfaces = [
    { name: "the chat composer", entry: "agent-pane.composer-strip", variant: "project", card: ".acpmux-composer-box" },
    {
      name: "a new chat's composer",
      entry: "agent-pane.composer-strip",
      variant: "no-project",
      card: ".acpmux-composer-box",
    },
    // The strip heads the New Tab card in the Default template with Claude's quiet row: Cards draws it
    // under its pill field, and since #24519 (2026-10-27, one quiet row) every other template with
    // Claude's plain footer draws it in the quiet row under the box (NewTabScreen.tsx locationInFooter).
    {
      name: "the New Tab composer",
      entry: "agent-pane.new-tab",
      variant: "layout-claude-chips-below",
      card: ".nt-box",
    },
  ];
  for (const surface of surfaces)
    for (const width of [420, 720])
      test(`${surface.name} at ${width} px: the strip heads the card, one controls row inside`, async () => {
        const page = await open(surface.entry, surface.variant, width);
        await page.locator(`${surface.card}`).waitFor();
        const measured = await page.evaluate(measureStrip, surface.card);
        await page.close();
        expect(measured.strip).not.toBeNull();
        expect(measured.stripFolder).toBe(true);
        const { strip, card } = measured as { strip: Rect; card: Rect };
        // The strip is text a few px over its card (Cursor's home, #21133), the chat's as the New Tab's.
        expect(card.top - strip.bottom).toBeGreaterThanOrEqual(2);
        expect(card.top - strip.bottom).toBeLessThanOrEqual(8);
        expect(strip.left).toBeGreaterThanOrEqual(card.left - 0.5);
        expect(strip.right).toBeLessThanOrEqual(card.right + 0.5);
        expect(measured.controlRows).toBe(1);
        expect(measured.locationInCard).toBe(0);
      });

  // The New Tab's strip has its own height (text over the card, #21133), so only the chat's compare.
  test("the strip is as tall with no project, with a project and while the host loads", async () => {
    const heights: Record<string, number> = {};
    for (const [entry, variant] of [
      ["agent-pane.composer-strip", "no-project"],
      ["agent-pane.composer-strip", "project"],
      ["agent-pane.composer-strip", "host-loading"],
    ] as const) {
      const page = await open(entry, variant, 720);
      await page.locator(".acpmux-composer-strip").waitFor();
      heights[`${entry}#${variant}`] = await page.evaluate(
        () => document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect().height,
      );
      await page.close();
    }
    const values = Object.values(heights);
    expect(values.every((height) => height > 0 && Math.abs(height - values[0]!) < 0.5)).toBe(true);
  });

  test("a started chat has no strip and no gap where it stood", async () => {
    const page = await open("agent-pane.composer-strip", "started", 720);
    await page.locator(".acpmux-composer-box").waitFor();
    const measured = await page.evaluate(measureStrip, ".acpmux-composer-box");
    await page.close();
    expect(measured.strip).toBeNull();
    const { form, card } = measured as { form: Rect; card: Rect };
    expect(Math.abs(card.top - form.top - measured.formPaddingTop)).toBeLessThanOrEqual(0.5);
  });

  test("a started chat's queued prompts sit on the card, with no strip between", async () => {
    const page = await open("agent-pane.composer-strip", "queued", 720);
    await page.locator(".acpmux-composer-queue").waitFor();
    const measured = await page.evaluate(measureStrip, ".acpmux-composer-box");
    await page.close();
    expect(measured.strip).toBeNull();
    const { queue, card } = measured as { queue: Rect; card: Rect };
    expect(Math.abs(card.top - queue.bottom)).toBeLessThanOrEqual(0.5);
  });

  test("effort and access: no placeholder while they load, and the controls hold their places", async () => {
    // The effort this harness's chats last showed (chipMemory.ts) and the start mode acpmux last
    // answered for it (startMode.ts), as an earlier chat left them.
    const remember = () => {
      localStorage.setItem("cmux.acpmux.lastChips", JSON.stringify({ claude: { effort: "Medium" } }));
      localStorage.setItem(
        "cmux.acpmux.startModes.v1",
        JSON.stringify({ "claude\u0000/home/dev/earlier": { modeId: "auto", name: "Auto" } }),
      );
    };
    const controls = async (variant: string) => {
      const page = await open("agent-pane.composer-strip", variant, 720, remember);
      await page.locator(".acpmux-composer-bar .acpmux-model").waitFor();
      const measured = await page.evaluate(() => {
        // The controls sit in the box's row and the quiet row under it (ComposerFoot.tsx).
        const bar = document.querySelector(".acpmux-composer")!;
        const left = (selector: string) => bar.querySelector(selector)?.getBoundingClientRect().left;
        return {
          placeholders: document.querySelectorAll(
            '.acpmux-composer [class*="skeleton"], .acpmux-composer [class*="shimmer"], .acpmux-composer [class*="placeholder-pill"]',
          ).length,
          plus: left(".acpmux-composer-plus"),
          model: left(".acpmux-model"),
          effort: left(".acpmux-model .acpmux-model-detail"),
          access: left(".acpmux-access"),
          // Claude desktop's box: no Send until there is a draft (Leo 2026-10-20); the mic is the
          // trailing control of this empty new chat.
          mic: left(".acpmux-mic"),
        };
      });
      await page.close();
      return measured;
    };
    const loading = await controls("awaiting");
    const arrived = await controls("reported");
    expect(loading.placeholders).toBe(0);
    expect(arrived.placeholders).toBe(0);
    for (const name of ["plus", "model", "effort", "access", "mic"] as const) {
      expect(loading[name]).toBeDefined();
      expect(Math.abs(loading[name]! - arrived[name]!)).toBeLessThanOrEqual(1);
    }
  });

  test("the folder popover names duplicates apart, keeps paths for hover and filters as typed", async () => {
    const page = await open("agent-pane.composer-context", "duplicate-worktrees", 720);
    // The variant's play opened the popover from the strip's Folder control.
    expect(await page.getByRole("button", { name: "Folder", exact: true }).getAttribute("aria-expanded")).toBe("true");
    const options = page.locator('.acpmux-location-menu [role="option"]:has(.acpmux-location-row)');
    await options.first().waitFor();
    const rows = async () =>
      options.evaluateAll((all) =>
        all.map((row) => ({
          text: (row.querySelector(".acpmux-menu-text")?.textContent ?? "").replace(/\s+/g, " ").trim(),
          title: row.querySelector("[title]")?.getAttribute("title"),
          checked: row.querySelector(".acpmux-location-check svg") !== null,
        })),
      );
    const all = await rows();
    // Duplicates carry their lane, a unique name none; no row prints a path.
    expect(all.map((row) => row.text)).toEqual([
      "cmux · cg-lane-adopt",
      "cmux · fleet-ci",
      "cmux · src",
      "atlas-web",
      "relay",
    ]);
    expect(all.every((row) => row.title?.startsWith("/Users/you/"))).toBe(true);
    expect(all.filter((row) => row.checked).map((row) => row.text)).toEqual(["cmux · cg-lane-adopt"]);
    // The search field has the keyboard: typing a lane keeps its row; a path's folder does too.
    await page.keyboard.type("fleet");
    await page.waitForFunction(
      () => document.querySelectorAll(".acpmux-location-menu .acpmux-location-row").length === 1,
    );
    expect((await rows()).map((row) => row.text)).toEqual(["cmux · fleet-ci"]);
    await page.getByRole("combobox", { name: "Search projects" }).fill("src");
    await page.waitForFunction(
      () => document.querySelectorAll(".acpmux-location-menu .acpmux-location-row").length === 3,
    );
    // Choose folder… closes the list, after the folders and the other existing rows.
    const actions = await page
      .locator(".acpmux-location-menu .acpmux-location-action")
      .evaluateAll((all) => all.map((row) => (row.textContent ?? "").trim()));
    expect(actions).toEqual(["New Worktree", "Add project", "Choose folder…"]);
    // ↓ moves the highlight from the first match to the next; Escape closes back to the strip.
    const highlighted = () =>
      page.evaluate(() =>
        document.querySelector(".acpmux-location-menu [data-highlighted] [title]")?.getAttribute("title"),
      );
    expect(await highlighted()).toBe("/Users/you/src/cmux");
    await page.keyboard.press("ArrowDown");
    expect(await highlighted()).toBe("/Users/you/src/atlas-web");
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => !document.querySelector(".acpmux-location-menu"));
    expect(await page.evaluate(() => document.activeElement?.getAttribute("aria-label"))).toBe("Folder");
    await page.close();
  });

  test("pinned actions leave a short pane repository list visible and keyboard-expandable", async () => {
    const page = await open("agent-pane.composer-context", "lane-checkouts", 720, undefined, 180);
    const menu = page.locator(".acpmux-folder-popover");
    const rect = await menu.boundingBox();
    expect(rect).not.toBeNull();
    expect(rect!.y + rect!.height).toBeLessThanOrEqual(180);
    const project = page.locator(".acpmux-location-row[data-expanded]").first();
    const viewport = page.locator(".ui-combobox-viewport");
    const projectRect = await project.boundingBox();
    const viewportRect = await viewport.boundingBox();
    expect(projectRect).not.toBeNull();
    expect(viewportRect).not.toBeNull();
    expect(viewportRect!.height).toBeGreaterThanOrEqual(projectRect!.height);
    expect(projectRect!.y).toBeGreaterThanOrEqual(viewportRect!.y);
    expect(projectRect!.y + projectRect!.height).toBeLessThanOrEqual(viewportRect!.y + viewportRect!.height);
    expect(viewportRect!.y + viewportRect!.height).toBeLessThanOrEqual(rect!.y + rect!.height);
    const search = page.getByRole("combobox", { name: "Search projects" });
    await search.press("ArrowDown");
    await search.press("ArrowDown");
    await search.press("ArrowRight");
    await page.waitForFunction(() => document.querySelector(".acpmux-location-row[data-worktree]"), undefined, {
      timeout: 5000,
    });
    await page.close();
  });

  for (const variant of ["folder-short-note", "folder-short-note-de", "folder-short-note-fr"]) {
    test(`${variant} leaves a visible project row in a short pane`, async () => {
      const page = await open("agent-pane.composer-context", variant, 720, undefined, 180);
      const popup = page.locator(".acpmux-folder-popover");
      const viewport = page.locator(".ui-combobox-viewport");
      const note = page.locator(".acpmux-location-note");
      const project = page.locator(".acpmux-location-row").first();
      const [popupRect, viewportRect, noteRect, projectRect] = await Promise.all([
        popup.boundingBox(),
        viewport.boundingBox(),
        note.boundingBox(),
        project.boundingBox(),
      ]);
      expect(popupRect).not.toBeNull();
      expect(viewportRect).not.toBeNull();
      expect(noteRect).not.toBeNull();
      expect(projectRect).not.toBeNull();
      expect(noteRect!.height).toBeLessThanOrEqual(16);
      const noteVisibility = await note.evaluate((element) => {
        const style = getComputedStyle(element);
        const range = document.createRange();
        range.selectNodeContents(element);
        const text = range.getBoundingClientRect();
        const box = element.getBoundingClientRect();
        return {
          lineHeight: parseFloat(style.lineHeight),
          paddingTop: parseFloat(style.paddingTop),
          paddingBottom: parseFloat(style.paddingBottom),
          borderTop: parseFloat(style.borderTopWidth),
          textTop: text.top,
          textBottom: text.bottom,
          boxTop: box.top,
          boxBottom: box.bottom,
        };
      });
      expect(noteVisibility.paddingTop + noteVisibility.paddingBottom + noteVisibility.borderTop).toBe(0);
      expect(noteVisibility.textTop).toBeGreaterThanOrEqual(noteVisibility.boxTop - 1);
      expect(noteVisibility.textBottom).toBeLessThanOrEqual(noteVisibility.boxBottom + 1);
      expect(noteRect!.height).toBeGreaterThanOrEqual(noteVisibility.lineHeight);
      expect(projectRect!.y).toBeGreaterThanOrEqual(viewportRect!.y);
      expect(projectRect!.y + projectRect!.height).toBeLessThanOrEqual(viewportRect!.y + viewportRect!.height);
      expect(viewportRect!.y + viewportRect!.height).toBeLessThanOrEqual(popupRect!.y + popupRect!.height);
      await page.close();
    });
  }

  test("a normal pane scrolls the last long-list project fully inside the popup", async () => {
    const page = await open("agent-pane.composer-context", "folder-long-list", 720);
    const popup = page.locator(".acpmux-folder-popover");
    const viewport = page.locator(".ui-combobox-viewport");
    await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
    });
    const last = page.locator(".acpmux-location-row").last();
    const [popupRect, viewportRect, lastRect] = await Promise.all([
      popup.boundingBox(),
      viewport.boundingBox(),
      last.boundingBox(),
    ]);
    expect(popupRect).not.toBeNull();
    expect(viewportRect).not.toBeNull();
    expect(lastRect).not.toBeNull();
    expect(viewportRect!.y + viewportRect!.height).toBeLessThanOrEqual(popupRect!.y + popupRect!.height);
    expect(lastRect!.y).toBeGreaterThanOrEqual(viewportRect!.y);
    expect(lastRect!.y + lastRect!.height).toBeLessThanOrEqual(viewportRect!.y + viewportRect!.height);
    await page.close();
  });

  test("the folder popover folds worktrees under their repository and opens them by arrow or count", async () => {
    const page = await open("agent-pane.composer-context", "repo-worktrees", 720);
    const rows = () =>
      page
        .locator('.acpmux-location-menu [role="option"] .acpmux-location-row')
        .evaluateAll((all) =>
          all.map(
            (row) =>
              (row.hasAttribute("data-worktree") ? "  " : "") +
              (row.querySelector(".acpmux-menu-text")?.textContent ?? "").replace(/\s+/g, " ").trim(),
          ),
        );
    // One cmux row, named by the current worktree's branch; its five folders are one project.
    expect(await rows()).toEqual(["cmux · issue-22273-runaway-children", "atlas-web", "relay", "notes"]);
    expect(await page.locator(".acpmux-location-worktrees").first().textContent()).toBe("4");
    // The strip names the repository, not the worktree's folder.
    expect(await page.getByRole("button", { name: "Folder", exact: true }).textContent()).toContain("cmux");
    // → opens the highlighted repository's other worktrees, newest first; ← closes them.
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowRight");
    await page.waitForFunction(() => document.querySelector(".acpmux-location-row[data-worktree]"));
    expect(await rows()).toEqual([
      "cmux · issue-22273-runaway-children",
      "  feat-cmux-next-unread-ring-classic",
      "  feat-cmux-next",
      "  agent-caller-scoped-current-selector",
      "  agent-21352-sidebar-drag",
      "atlas-web",
      "relay",
      "notes",
    ]);
    await page.keyboard.press("ArrowLeft");
    await page.waitForFunction(() => !document.querySelector(".acpmux-location-row[data-worktree]"));
    // The count opens them too, and a press on it never picks the row.
    await page.locator(".acpmux-location-worktrees").first().click();
    await page.waitForFunction(() => document.querySelector(".acpmux-location-row[data-worktree]"));
    expect(await page.locator(".acpmux-location-menu").count()).toBe(1);
    // A branch search lists the worktree it names under its repository; the repository's name, once.
    await page.getByRole("combobox", { name: "Search projects" }).fill("unread");
    await page.waitForFunction(
      () => document.querySelectorAll(".acpmux-location-menu .acpmux-location-row").length === 2,
    );
    expect(await rows()).toEqual(["cmux · issue-22273-runaway-children", "  feat-cmux-next-unread-ring-classic"]);
    await page.getByRole("combobox", { name: "Search projects" }).fill("cmux");
    await page.waitForFunction(
      () => document.querySelectorAll(".acpmux-location-menu .acpmux-location-row").length === 1,
    );
    await page.close();
  });

  test("an older host's worktrees still fold under their repository by path", async () => {
    const page = await open("agent-pane.composer-context", "repo-worktrees-guessed", 720);
    const names = await page
      .locator('.acpmux-location-menu [role="option"] .acpmux-location-row')
      .evaluateAll((all) => all.map((row) => (row.querySelector(".acpmux-menu-label")?.textContent ?? "").trim()));
    expect(names).toEqual(["cmux", "atlas-web", "relay", "notes"]);
    await page.close();
  });

  /** Runs in the page: the strip's controls against the prompt's edges. */
  function measureMarks() {
    const rect = (element: Element | null | undefined) => {
      if (!element) return null;
      const { left, right, top, bottom, width } = element.getBoundingClientRect();
      return { left, right, top, bottom, width };
    };
    // A stroke icon's drawn ink, left to right in page px: its shapes' boxes widened by half their
    // stroke, mapped through the icon's viewBox. The ink lies a different way inside each icon's box
    // (the mic's ~2.7 px, the chevron's ~3.5 px), so the marks are compared ink to ink.
    const ink = (element: Element | null | undefined) => {
      const svg = element instanceof SVGSVGElement ? element : element?.querySelector("svg");
      const shapes = [
        ...(svg?.querySelectorAll<SVGGraphicsElement>("path, line, circle, rect, polyline, polygon") ?? []),
      ];
      const edges = shapes.flatMap((shape) => {
        const box = shape.getBBox();
        const matrix = shape.getScreenCTM();
        if (!matrix) return [];
        const style = getComputedStyle(shape);
        const half = style.stroke === "none" ? 0 : parseFloat(style.strokeWidth) / 2;
        return [matrix.a * (box.x - half) + matrix.e, matrix.a * (box.x + box.width + half) + matrix.e];
      });
      return edges.length ? { left: Math.min(...edges), right: Math.max(...edges) } : null;
    };
    const strip = document.querySelector(".acpmux-composer-strip")!;
    const pickers = [...strip.querySelectorAll<HTMLElement>(".acpmux-location-picker")];
    const computer = strip.querySelector<HTMLElement>('.acpmux-location-picker[data-kind="computer"]');
    const branch = pickers.at(-1)!;
    const branchLabel = branch.querySelector<HTMLElement>(".acpmux-location-label")!;
    const computerLabel = computer?.querySelector<HTMLElement>(".acpmux-location-label");
    const head = strip.querySelector<HTMLElement>(".acpmux-location-head");
    return {
      prompt: rect(
        document.querySelector(".acpmux-composer-box .acpmux-input, .acpmux-composer-box [contenteditable]"),
      ),
      // The Claude desktop box (composerLocation.css): + and the trailing actions sit beside the
      // prompt, so the box's columns are the + glyph and the last action's glyph: the mic in this
      // empty new chat (no Send until there is a draft, Leo 2026-10-20), Send with one.
      plusInk: ink(document.querySelector(".acpmux-composer-inner .acpmux-composer-plus .acpmux-icon")),
      trailInk: ink(
        [...document.querySelectorAll(".acpmux-composer-inner .acpmux-composer-actions .acpmux-icon")].at(-1),
      ),
      strip: rect(strip),
      folderInk: ink(pickers[0]?.querySelector(".acpmux-location-icon")),
      branchChevronInk: ink(branch.querySelector(".ui-ghost-icon:last-child")),
      text: strip.textContent ?? "",
      head: head ? { clipped: head.scrollWidth > head.clientWidth + 0.5, text: head.textContent } : null,
      tail: rect(strip.querySelector(".acpmux-location-tail")),
      tailText: strip.querySelector(".acpmux-location-tail")?.textContent,
      computerLabelShown: computerLabel ? getComputedStyle(computerLabel).display !== "none" : null,
      computerIcon: rect(computer?.querySelector(".acpmux-location-icon")),
      computerName: computer
        ? (computer.getAttribute("title") ?? computer.querySelector("[title]")?.getAttribute("title") ?? "")
        : null,
      branchClipped: branchLabel.scrollWidth > branchLabel.clientWidth + 0.5,
      // Range.getBoundingClientRect is fractional, so a sub-pixel cut (an ellipsis on "This Mac")
      // shows where scrollWidth would round it away.
      computerClipped: (() => {
        if (!computerLabel || getComputedStyle(computerLabel).display === "none") return null;
        const range = document.createRange();
        range.selectNodeContents(computerLabel);
        return range.getBoundingClientRect().width > computerLabel.getBoundingClientRect().width + 0.01;
      })(),
      // Room left in the leading group after its last control (the folder cuts only to fit).
      leadingSlack: (() => {
        const leading = strip.querySelector(".acpmux-location-leading")!.getBoundingClientRect();
        const last = strip.querySelector(".acpmux-location-leading > :last-child")!.getBoundingClientRect();
        return leading.right - last.right;
      })(),
    };
  }

  for (const width of [420, 760])
    test(`the chat composer at ${width} px: the strip's marks line up with the prompt's edges`, async () => {
      const page = await open("agent-pane.composer-strip", "project", width);
      await page.locator(".acpmux-composer-strip .acpmux-location-icon").first().waitFor();
      const marks = await page.evaluate(measureMarks);
      await page.close();
      const prompt = marks.prompt!;
      const folderInk = marks.folderInk!;
      const chevronInk = marks.branchChevronInk!;
      // The marks sit over the box's content edges: the prompt's, or the ink of + and of the last
      // action (the mic at rest) where they stand beside it. Both offsets in one check, so a failure
      // names both. The folder's ink starts 2.0 px before the +'s (CI, 2026-10-21): within half a
      // pixel more of that, the strip still reads as lined up.
      const lead = marks.plusInk?.left ?? prompt.left;
      const trail = marks.trailInk?.right ?? prompt.right;
      const offsets = { lead: folderInk.left - lead, trail: chevronInk.right - trail };
      expect(
        Math.max(Math.abs(offsets.lead), Math.abs(offsets.trail)),
        `the folder's ink is ${offsets.lead.toFixed(2)} px from the leading mark's, the branch chevron's ${offsets.trail.toFixed(2)} px from the last action's`,
      ).toBeLessThanOrEqual(2.5);
      expect(marks.text).not.toContain("·");
      // At or under 460 px the computer is its icon (the strip's first step).
      expect(marks.computerLabelShown).toBe(width > 460);
    });

  // The strip's steps (compact-composer verdict 4; composerLocation.css): pane widths, at or under.
  // At 460 the computer shows its laptop icon alone, named by its label and tooltip; at 340 the
  // folder cuts in the middle and keeps both ends. The branch keeps its name at every step.
  for (const [width, iconOnly] of [
    [461, false],
    [460, true],
  ] as const)
    test(`the chat composer at ${width} px: the computer ${iconOnly ? "shows its icon alone" : "keeps its name"}`, async () => {
      const page = await open("agent-pane.composer-strip", "project", width);
      await page.locator(".acpmux-composer-strip .acpmux-location-icon").first().waitFor();
      const marks = await page.evaluate(measureMarks);
      const label = await page
        .locator('.acpmux-composer-strip .acpmux-location-picker[data-kind="computer"] button')
        .getAttribute("aria-label");
      await page.close();
      expect(marks.computerLabelShown).toBe(!iconOnly);
      expect(marks.computerIcon!.width).toBeGreaterThan(0);
      // Named for the pointer and VoiceOver either way.
      expect(marks.computerName).toContain("This Mac");
      expect(label).toBe("Environment: This Mac");
      if (!iconOnly) expect(marks.computerClipped).toBe(false);
      expect(marks.branchClipped).toBe(false);
    });

  for (const [width, cut] of [
    [341, false],
    [340, true],
  ] as const)
    test(`the chat composer at ${width} px: a folder name ${cut ? "cuts in the middle and keeps its last word" : "shows whole"}`, async () => {
      const page = await open("agent-pane.composer-strip", "mid-folder", width);
      await page.locator(".acpmux-composer-strip .acpmux-location-tail").waitFor();
      const marks = await page.evaluate(measureMarks);
      await page.close();
      const strip = marks.strip!;
      const tail = marks.tail!;
      // The head takes the ellipsis ("atl…"); the last word stays whole and inside the strip.
      // The fixture's folder (composerStrip.gallery.ts mid-folder) is sized to the strip's step: the
      // strip became chips over the card (#25304), so "atlas-web-checkout" now sits on it.
      expect(marks.head).toEqual({ clipped: cut, text: "atlas-web-" });
      expect(marks.tailText).toBe("checkout");
      expect(tail.width).toBeGreaterThan(0);
      expect(tail.right).toBeLessThanOrEqual(strip.right);
      expect(marks.computerLabelShown).toBe(false);
      expect(marks.branchClipped).toBe(false);
    });

  test("the chat composer at 760 px: a long folder name shows whole when the strip has room", async () => {
    const page = await open("agent-pane.composer-strip", "long-folder", 760);
    await page.locator(".acpmux-composer-strip .acpmux-location-tail").waitFor();
    const marks = await page.evaluate(measureMarks);
    await page.close();
    // No fixed cap cuts it beside empty strip.
    expect(marks.head).toEqual({ clipped: false, text: "atlas-web-checkout-" });
    expect(marks.computerLabelShown).toBe(true);
  });

  test("the chat composer at 290 px: the folder still keeps both ends and the branch its name", async () => {
    const page = await open("agent-pane.composer-strip", "long-folder", 290);
    await page.locator(".acpmux-composer-strip .acpmux-location-tail").waitFor();
    const marks = await page.evaluate(measureMarks);
    await page.close();
    expect(marks.head?.clipped).toBe(true);
    expect(marks.tailText).toBe("service");
    expect(marks.tail!.right).toBeLessThanOrEqual(marks.strip!.right);
    expect(marks.branchClipped).toBe(false);
  });

  // Focus draws no ring (Leo 2026-10-19): a focused strip control keeps the strip's geometry, and its
  // edge takes the composer's focused tone, as the card's does (#21241; #23745: a step brighter).
  test("focusing a strip control steps the strip's edge tone and keeps its geometry", async () => {
    const page = await open("agent-pane.composer-strip", "project", 420);
    await installPaintedFrames(page);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.evaluate(() => window.cmuxPaintFrame());
    const before = await page.evaluate(() => {
      const strip = document.querySelector<HTMLElement>(".acpmux-composer-strip")!;
      const rect = strip.getBoundingClientRect();
      return {
        edge: getComputedStyle(strip).getPropertyValue("--acpmux-strip-edge"),
        rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      };
    });
    await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-composer-strip button")!.focus());
    await page.evaluate(() => window.cmuxPaintFrame());
    const after = await page.evaluate(() => {
      const strip = document.querySelector<HTMLElement>(".acpmux-composer-strip")!;
      const rect = strip.getBoundingClientRect();
      return {
        edge: getComputedStyle(strip).getPropertyValue("--acpmux-strip-edge"),
        rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      };
    });
    const focusEdge = await page.evaluate(() =>
      getComputedStyle(document.querySelector<HTMLElement>(".acpmux-composer")!)
        .getPropertyValue("--acpmux-composer-edge-focus")
        .trim(),
    );
    await page.close();
    expect(after.edge.replace(/\s+/g, "")).toBe(focusEdge.replace(/\s+/g, ""));
    expect(after.edge).not.toBe(before.edge);
    expect(after.rect).toEqual(before.rect);
  });
  test("long environment menu scrolls to its last machine", async () => {
    const page = await open("agent-pane.composer-context", "environment-picker-fleet", 720);
    const list = page.locator(".acpmux-env-popover .acpmux-location-folders");
    const before = await list.evaluate((node) => ({ height: node.clientHeight, total: node.scrollHeight }));
    expect(before.total).toBeGreaterThan(before.height);
    await list.hover();
    await page.mouse.wheel(0, 3000);
    await page.waitForFunction(() => {
      const list = document.querySelector<HTMLElement>(".acpmux-env-popover .acpmux-location-folders");
      return list != null && list.scrollTop > 0;
    });
    expect(await list.evaluate((node) => node.scrollTop)).toBeGreaterThan(0);
    const last = list.locator("[role=option]").last();
    expect(await last.isVisible()).toBe(true);
    expect(
      await last.evaluate((node) => {
        const list = node.closest(".acpmux-location-folders")!.getBoundingClientRect();
        const row = node.getBoundingClientRect();
        return row.bottom <= list.bottom && row.top >= list.top;
      }),
    ).toBe(true);
    await page.close();
  });

  for (const [entry, variant] of [
    ["agent-pane.composer-context", "folder-pinned-search"],
    ["agent-pane.project-chooser", "open-current"],
  ]) {
    for (const query of ["relay", "/Users/you/src/relay"]) {
      test(`${entry} highlights ${query} as the active project before Enter`, async () => {
        const page = await open(entry, variant, 720);
        const field = page.getByRole("combobox", { name: "Search projects" });
        await field.fill(query);
        await page.waitForFunction(() => document.querySelector("[data-highlighted]"));
        const activeId = await field.getAttribute("aria-activedescendant");
        const highlighted = page.locator("[data-highlighted]");
        expect(activeId).toBeTruthy();
        expect(await highlighted.getAttribute("id")).toBe(activeId);
        expect(await highlighted.textContent()).toContain("relay");
        expect(await highlighted.locator(".acpmux-location-action").count()).toBe(0);
        await field.press("Enter");
        expect(await page.evaluate(() => document.documentElement.dataset.galleryProjectPicked)).toBe(
          "/Users/you/src/relay",
        );
        expect(await page.evaluate(() => document.documentElement.dataset.galleryProjectAction)).toBeUndefined();
        await page.close();
      });
    }
  }
  for (const [entry, variant] of [
    ["agent-pane.composer-context", "folder-pinned-search"],
    ["agent-pane.project-chooser", "open-current"],
  ]) {
    test(`${entry} keeps pinned actions deliberately reachable by keyboard`, async () => {
      const page = await open(entry, variant, 720);
      const field = page.getByRole("combobox", { name: "Search projects" });
      await field.fill("relay");
      await page.waitForFunction(() => document.querySelector("[data-highlighted]")?.textContent?.includes("relay"));
      await field.press("ArrowDown");
      const activeId = await field.getAttribute("aria-activedescendant");
      const highlighted = page.locator("[data-highlighted]");
      expect(await highlighted.getAttribute("id")).toBe(activeId);
      expect(await highlighted.textContent()).toContain("Do not work in a project");
      await field.press("Enter");
      expect(await page.evaluate(() => document.documentElement.dataset.galleryProjectAction)).toBe("none");
      expect(await page.evaluate(() => document.documentElement.dataset.galleryProjectPicked)).toBeUndefined();
      await page.close();
    });
  }
  test("a long project list without actions wheels to its last folder", async () => {
    const page = await open("agent-pane.project-chooser", "long-no-actions", 720);
    const list = page.locator(".acpmux-project-menu .acpmux-project-folders");
    expect(await list.locator("[role=option]").count()).toBe(40);
    expect(await page.locator(".acpmux-project-menu .ui-combobox-pinned").count()).toBe(0);
    expect(await list.evaluate((node) => node.scrollHeight)).toBeGreaterThan(
      await list.evaluate((node) => node.clientHeight),
    );
    await list.hover();
    await page.mouse.wheel(0, 3000);
    await page.waitForFunction(
      () => {
        const list = document.querySelector<HTMLElement>(".acpmux-project-menu .acpmux-project-folders");
        return list != null && list.scrollTop > 0;
      },
      null,
      { timeout: 1500 },
    );
    const last = list.locator("[role=option]").last();
    expect(
      await last.evaluate((node) => {
        const row = node.getBoundingClientRect();
        const viewport = node.closest(".acpmux-project-folders")!.getBoundingClientRect();
        return row.top >= viewport.top && row.bottom <= viewport.bottom;
      }),
    ).toBe(true);
    await list.evaluate((node) => {
      node.scrollTop = 0;
    });
    await page.getByRole("combobox", { name: "Search projects" }).focus();
    for (let index = 0; index < 40; index++) await page.keyboard.press("ArrowDown");
    expect(await last.getAttribute("data-highlighted")).not.toBeNull();
    expect(
      await last.evaluate((node) => {
        const row = node.getBoundingClientRect();
        const viewport = node.closest(".acpmux-project-folders")!.getBoundingClientRect();
        return row.top >= viewport.top && row.bottom <= viewport.bottom;
      }),
    ).toBe(true);
    await page.close();
  });

  test("Escape from a pinned project action closes and restores trigger focus", async () => {
    const page = await open("agent-pane.composer-context", "folder-long-list", 720);
    const popup = page.locator(".acpmux-folder-popover");
    const option = popup.locator(".ui-combobox-pinned [role=option]").first();
    expect(await option.count()).toBe(1);
    await popup.locator('input[role="combobox"]').press("Escape");
    await popup.waitFor({ state: "detached" });
    expect(await page.evaluate(() => document.activeElement?.getAttribute("aria-label"))).toBe("Folder");
    await page.close();
  });

  test("project actions stay pinned while the inside thumb scrolls without dismissing", async () => {
    const page = await open("agent-pane.composer-context", "folder-long-list", 720);
    const popup = page.locator(".acpmux-folder-popover");
    const actions = popup.locator(".ui-combobox-pinned");
    const action = actions.locator("[role=option]").first();
    expect(await action.count()).toBe(1);
    expect(await action.evaluate((node) => getComputedStyle(node).borderTopWidth)).toBe("0px");
    const thumb = popup.locator(".cmux-scrollbar-thumb").first();
    await thumb.waitFor({ state: "visible" });
    const before = await actions.boundingBox();
    const bounds = await popup.boundingBox();
    const grip = await thumb.boundingBox();
    expect(grip!.x + grip!.width).toBeLessThanOrEqual(bounds!.x + bounds!.width);
    await page.mouse.move(grip!.x + grip!.width / 2, grip!.y + grip!.height / 2);
    await page.mouse.down();
    await page.mouse.move(grip!.x + grip!.width / 2, grip!.y + grip!.height / 2 + 80, { steps: 5 });
    await page.mouse.up();
    expect(await popup.count()).toBe(1);
    expect(await actions.boundingBox()).toEqual(before);
    expect(await popup.locator(".ui-combobox-viewport").evaluate((node) => node.scrollTop)).toBeGreaterThan(0);
    await page.close();
  });
});
