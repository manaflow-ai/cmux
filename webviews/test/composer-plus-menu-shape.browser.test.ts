// cmux-web-test-timeout: 300
// The composer's + menu in the real gallery stages, laid out by Chromium (Leo, 2026-10-31: "our +
// button is ass" / "inside chat and in the composer it's ass"; the reference is ChatGPT's + menu):
// - skills are not rows of +: a chat with 30 skills shows one Commands and skills… row, which opens the slash list;
// - each row's title and muted description sit on one line with a gap between them;
// - the menu's height is bounded, and it scrolls inside past that;
// - New Tab's + covers the project and machine pills behind it: it is on top where they overlap, and
//   its glass frosts them (no backdrop root around it), or it is opaque.
// With FAST_CHECKS_OUT set it writes 2x stills of both states, light and dark, before it asserts, so a
// run at the base draws the "before" of the same states.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("composer-plus-menu-shape.browser.test.ts", async () => {
  setDefaultTimeout(150_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-plus-menu-shape: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer plus menu shape", () => test("chromium", () => {}));
    return;
  }
  const STATES = {
    chat: { entry: "agent-pane.composer", variant: "add-menu-skills", plus: ".acpmux-composer-plus", width: 720 },
    newTab: { entry: "agent-pane.new-tab", variant: "attachment-menu-pills", plus: ".acpmux-newtab-plus", width: 900 },
  } as const;
  type State = keyof typeof STATES;
  const HEIGHT = 820;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const state of Object.values(STATES))
      await warmGalleryFrame(vite, state.entry, { browser, params: { variant: state.variant } });
    if (out) await mkdir(out, { recursive: true });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The state's stage with its + menu open (its play opens it before the stage reports ready). */
  async function opened(state: State, colorScheme: "light" | "dark" = "dark"): Promise<Page> {
    const { entry, variant, plus, width } = STATES[state];
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: HEIGHT }, deviceScaleFactor: 2 });
    // No recent commands carried in (recentCommands.ts): the + menu's commands group is the one row.
    await page.addInitScript(() => localStorage.removeItem("cmux.acpmux.recentSlashCommands"));
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme, reducedMotion: "true", width, height: HEIGHT })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.waitForSelector(`${plus} .acpmux-menu .acpmux-menu-item`);
    return page;
  }

  /** The open menu's popup, its rows and the pills a New Tab composer draws above its box. */
  function read(page: Page, state: State) {
    return page.evaluate((plus) => {
      const box = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, height: rect.height };
      };
      const popup = document.querySelector<HTMLElement>(`${plus} .acpmux-menu`)!;
      const css = getComputedStyle(popup);
      const rows = [...popup.querySelectorAll<HTMLElement>(".acpmux-menu-item")].map((row) => {
        const label = row.querySelector(".acpmux-menu-label");
        const description = row.querySelector(".acpmux-menu-description");
        return {
          id: row.dataset.value ?? "",
          text: label?.textContent ?? "",
          height: row.getBoundingClientRect().height,
          label: label ? box(label) : null,
          description: description ? box(description) : null,
        };
      });
      // A backdrop root around the popup: inside one, its backdrop-filter sees only that root's
      // content, so what is behind the composer shows through unfrosted (Filter Effects 2).
      let root = "";
      for (let node = popup.parentElement; node && node !== document.body; node = node.parentElement) {
        const style = getComputedStyle(node);
        const backdrop = style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter");
        const mask = style.maskImage || style.getPropertyValue("-webkit-mask-image");
        if (
          (backdrop && backdrop !== "none") ||
          (style.filter && style.filter !== "none") ||
          (mask && mask !== "none") ||
          Number.parseFloat(style.opacity) < 1
        ) {
          root = node.className || node.tagName;
          break;
        }
      }
      const pills = [...document.querySelectorAll(".nt-above .acpmux-composer-strip button")]
        .map(box)
        .filter((pill) => pill.height > 0);
      // The fill's alpha: `rgba(r, g, b, a)` or `color(srgb r g b / a)`; none written is opaque.
      const written = /(?:,|\/)\s*([\d.]+)(%?)\s*\)\s*$/.exec(css.backgroundColor);
      const alpha = written ? Number.parseFloat(written[1]!) / (written[2] ? 100 : 1) : 1;
      return {
        popup: box(popup),
        maxHeight: css.maxHeight,
        scrolls: popup.scrollHeight > popup.clientHeight + 1,
        overflowY: css.overflowY,
        headers: popup.querySelectorAll(".acpmux-menu-header").length,
        backdrop: css.backdropFilter || css.getPropertyValue("-webkit-backdrop-filter"),
        alpha,
        root,
        rows,
        pills,
      };
    }, STATES[state].plus);
  }

  async function still(page: Page, state: State, colorScheme: string) {
    if (!out) return;
    const { popup } = await read(page, state);
    // The menu and the composer it rises from, with a margin.
    const composer = await page
      .locator(state === "chat" ? ".acpmux-composer-box" : ".nt-composer")
      .first()
      .boundingBox();
    const top = Math.max(0, Math.min(popup.top, composer?.y ?? popup.top) - 24);
    const bottom = Math.min(HEIGHT, Math.max(popup.bottom, (composer?.y ?? 0) + (composer?.height ?? 0)) + 24);
    await page.screenshot({
      path: path.join(out, `plus-menu-${state}-${colorScheme}.png`),
      clip: { x: 0, y: top, width: STATES[state].width, height: bottom - top },
    });
  }

  // The stills first, in both schemes, so a red run still draws them.
  test("stills of both + menus, light and dark (with FAST_CHECKS_OUT)", async () => {
    for (const state of ["chat", "newTab"] as const)
      for (const colorScheme of ["light", "dark"] as const) {
        const page = await opened(state, colorScheme);
        await still(page, state, colorScheme);
        console.log(`composer-plus-menu-shape ${state} ${colorScheme}: ${JSON.stringify(await read(page, state))}`);
        await page.close();
      }
  });

  test("a chat with 30 skills lists no skill in +: one Commands and skills… row opens the slash list", async () => {
    const page = await opened("chat");
    const { rows } = await read(page, "chat");
    expect(rows.filter((row) => row.id.startsWith("add.skill.") || row.text.startsWith("/"))).toEqual([]);
    const skills = rows.filter((row) => row.id === "add.commands");
    expect(skills.map((row) => row.text)).toEqual(["Commands and skills…"]);
    // Attach on top, then the other actions; none is removed.
    expect(rows.slice(0, 3).map((row) => row.id)).toEqual(["add.files", "add.screenshot", "add.window"]);
    for (const id of ["add.mode.plan", "add.goal", "add.mention", "files.search"])
      expect(rows.some((row) => row.id === id)).toBe(true);
    await page.click(`${STATES.chat.plus} [data-value="add.commands"]`);
    const slash = await page
      .waitForSelector(".acpmux-slash-menu", { state: "attached", timeout: 5_000 })
      .then(() => true)
      .catch(() => false);
    if (!slash)
      console.log(
        `composer-plus-menu-shape: no slash list after Commands and skills… ${JSON.stringify(
          await page.evaluate(() => {
            const active = document.activeElement;
            const selection = document.getSelection();
            return {
              active: active ? `${active.tagName}.${active.className}` : null,
              prompt: document.querySelector(".acpmux-composer-prompt")?.textContent ?? null,
              caret: selection?.anchorOffset ?? null,
              plusOpen: !!document.querySelector(".acpmux-composer-plus .acpmux-menu"),
              escaped: document.querySelector("[data-escaped]")?.className ?? null,
            };
          }),
        )}`,
      );
    expect(slash).toBe(true);
    await page.close();
  });

  for (const state of ["chat", "newTab"] as const)
    test(`the ${state} +: a row's title and description sit on one line, with a gap`, async () => {
      const page = await opened(state);
      const { rows, headers } = await read(page, state);
      // No header band drawn like an input between the groups (a hairline splits them).
      expect(headers).toBe(0);
      const described = rows.filter((row) => row.description);
      expect(described.length).toBeGreaterThan(0);
      for (const row of described) {
        const label = row.label!;
        const description = row.description!;
        expect(description.left - label.right, `${row.id}: gap`).toBeGreaterThanOrEqual(4);
        expect(Math.abs(description.top - label.top), `${row.id}: one line`).toBeLessThanOrEqual(4);
        expect(row.height, `${row.id}: one row tall`).toBeLessThanOrEqual(32);
      }
      await page.close();
    });

  for (const state of ["chat", "newTab"] as const)
    test(`the ${state} + menu's height is bounded and it scrolls inside`, async () => {
      const page = await opened(state);
      const menu = await read(page, state);
      expect(menu.popup.height).toBeLessThanOrEqual(360);
      expect(Number.parseFloat(menu.maxHeight)).toBeLessThanOrEqual(360);
      expect(menu.overflowY).toMatch(/auto|scroll/);
      await page.close();
    });

  test("New Tab's + covers the project and machine pills: on top, and not seen through", async () => {
    const page = await opened("newTab");
    const menu = await read(page, "newTab");
    const covered = menu.pills.filter(
      (pill) =>
        pill.left < menu.popup.right &&
        pill.right > menu.popup.left &&
        pill.top < menu.popup.bottom &&
        pill.bottom > menu.popup.top,
    );
    // The state is the one Leo showed: the menu opens over the pills.
    expect(covered.length).toBeGreaterThan(0);
    for (const pill of covered) {
      const x = (Math.max(pill.left, menu.popup.left) + Math.min(pill.right, menu.popup.right)) / 2;
      const y = (Math.max(pill.top, menu.popup.top) + Math.min(pill.bottom, menu.popup.bottom)) / 2;
      const onTop = await page.evaluate(
        ([px, py, plus]) => !!document.elementFromPoint(px as number, py as number)?.closest(`${plus} .acpmux-menu`),
        [x, y, STATES.newTab.plus] as const,
      );
      expect(onTop).toBe(true);
    }
    // Its own glass frosts what is behind it: no backdrop root around it, and a blur or an opaque fill.
    expect(menu.root).toBe("");
    // Opaque, or glass dense enough over its blur that the pills read as frost, not text.
    expect(menu.alpha >= 0.9 || (/blur/.test(menu.backdrop) && menu.alpha >= 0.8)).toBe(true);
    await page.close();
  });
});
