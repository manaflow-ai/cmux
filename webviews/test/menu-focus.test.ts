// cmux-web-test-timeout: 240
// An open menu never draws a focus ring around itself, and its items are at full ink (Leo
// 2026-10-11, the New Tab "…" menu: "hella ugly"). The popup takes focus when it opens so its keys
// work, and the global keyboard ring (desktop.css) drew a thick square around the whole menu, while
// the items sat at the dimmed tone of a disabled row until hovered. A keyboard-opened menu
// highlights its first item with the row highlight; a mouse-opened one highlights nothing.
//
// The gallery plays the menus on the real dev server in WebKit (the app's engine), Chromium where
// WebKit is not installed: the agent pane's header menu (the pane's own stylesheet) and the shared
// Menu primitive's entry. Each opens by a click and by the keyboard.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { loadEntries } from "../scripts/gallery/entries";
import { stopDevServer } from "./support/devServer";
import { galleryFrame, reloaded, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("menu-focus.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");

  let engine: BrowserType | null = null;
  for (const candidate of [webkit, chromium]) {
    try {
      await (await candidate.launch({ headless: true })).close();
      engine = candidate;
      break;
    } catch {
      // The next engine.
    }
  }
  const installed = engine !== null;
  // Each entry's menu button, by its accessible name.
  const TRIGGERS: Record<string, string> = { "agent-pane.header-tools": "Chat actions", "ui.menu": "Open demo menu" };
  const ENTRIES = Object.keys(TRIGGERS);
  const THEMES = [
    { theme: "Apple System Colors Light", colorScheme: "light" },
    { theme: "Apple System Colors", colorScheme: "dark" },
  ];
  const entries = new Map((await loadEntries()).map((entry) => [entry.id, entry]));

  let server: ChildProcess | null = null;
  let browser: Browser | null = null;
  let base = "";

  beforeAll(async () => {
    if (!installed) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
    });
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    browser = await engine!.launch({ headless: true });
    // The first loads compile the gallery and can run Vite's dependency optimizer, which reloads
    // the page: with a cold server, whichever test came first timed out in `goto` or lost its page
    // (CI, 2026-10-12). Every entry loads once here, so the tests start on a warm server.
    // Under the file's 240 s limit, so a stalled warm-up fails here, naming its entry.
    await warmGalleryFrame(base, ENTRIES, { browser, timeoutMs: 150_000 });
  }, 200_000);

  afterAll(async () => {
    await browser?.close();
    stopDevServer(server);
  });

  /** The open menu: its own ring, the items that are not at the menu's ink, and the highlighted one. */
  function openMenu(page: Page) {
    return page.evaluate(() => {
      const menu = document.querySelector<HTMLElement>('[role="menu"]');
      if (!menu) return undefined;
      const style = getComputedStyle(menu);
      const ring =
        style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0
          ? `${style.outlineStyle} ${style.outlineWidth}`
          : "";
      const items = [...menu.querySelectorAll<HTMLElement>('[role^="menuitem"]')].filter(
        (item) => item.closest('[role="menu"]') === menu,
      );
      const enabled = items.filter(
        (item) =>
          !item.hasAttribute("data-disabled") &&
          item.getAttribute("aria-disabled") !== "true" &&
          !item.className.includes("destructive"),
      );
      const dimmed = enabled
        .filter((item) => {
          const look = getComputedStyle(item);
          return look.color !== style.color || Number(look.opacity) < 1;
        })
        .map((item) => item.textContent?.trim() ?? "");
      const highlighted = items.findIndex((item) => item.hasAttribute("data-highlighted"));
      return { ring, dimmed, highlighted, focusInMenu: menu.contains(document.activeElement) };
    });
  }

  /** Opens the entry's first variant and waits for the gallery, through a reload of the page. */
  async function load(page: Page, entry: string, theme: string, colorScheme: string) {
    const variant = Object.keys(entries.get(entry)!.variants)[0]!;
    const url = `${base}${galleryFrame(entry, { variant, theme, colorScheme, frame: "component", width: "760", height: "640" })}`;
    const deadline = Date.now() + 120_000;
    const left = () => Math.max(1, deadline - Date.now());
    let navigated = false;
    for (;;) {
      try {
        if (!navigated) await page.goto(url, { waitUntil: "commit", timeout: left() });
        navigated = true;
        // "1" when the stage drew, "error" when it failed (its message is the page's text).
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, null, {
          timeout: left(),
        });
        if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) === "1") return;
        throw new Error(`gallery ${entry}: ${await page.evaluate(() => document.body.textContent?.trim())}`);
      } catch (error) {
        // An optimizer reload destroys the page's context (or interrupts the navigation): wait again.
        if (Date.now() >= deadline || !reloaded(error)) throw error;
      }
    }
  }

  async function stage(page: Page, entry: string, theme: string, colorScheme: string) {
    await load(page, entry, theme, colorScheme);
    return page.getByRole("button", { name: TRIGGERS[entry], exact: true }).first();
  }

  describe("an open menu draws no ring and its items are at full ink", () => {
    for (const entry of ENTRIES)
      for (const { theme, colorScheme } of THEMES)
        test.skipIf(!installed)(`${entry} (${colorScheme})`, async () => {
          if (!browser) throw new Error("menu-focus: the browser did not launch");
          expect(entries.has(entry)).toBe(true);
          const page = await browser.newPage({ viewport: { width: 1000, height: 760 } });
          try {
            const trigger = await stage(page, entry, theme, colorScheme);
            // By the mouse: no highlight until the pointer moves onto an item.
            await page.mouse.move(1, 1);
            await trigger.click();
            await page.locator('[role="menu"]').first().waitFor({ state: "visible" });
            // The popup takes focus as it opens: read it once it has.
            await page
              .waitForFunction(() => document.querySelector('[role="menu"]')?.contains(document.activeElement), null, {
                timeout: 5_000,
              })
              .catch(() => undefined);
            const byMouse = await openMenu(page);
            await page.keyboard.press("Escape");
            await page.locator('[role="menu"]').first().waitFor({ state: "detached" });
            // By the keyboard: the first item highlighted, as the row highlight.
            await trigger.focus();
            await page.keyboard.press("ArrowDown");
            await page.locator('[role="menu"]').first().waitFor({ state: "visible" });
            // WebKit highlights the first item before the popup takes focus: read once both have.
            await page
              .waitForFunction(
                () => {
                  const menu = document.querySelector('[role="menu"]');
                  return !!menu?.querySelector("[data-highlighted]") && menu.contains(document.activeElement);
                },
                null,
                { timeout: 5_000 },
              )
              .catch(() => undefined);
            const byKeyboard = await openMenu(page);
            expect({ byMouse, byKeyboard }).toEqual({
              byMouse: { ring: "", dimmed: [], highlighted: -1, focusInMenu: true },
              byKeyboard: { ring: "", dimmed: [], highlighted: 0, focusInMenu: true },
            });
          } finally {
            await page.close();
          }
        });
  });
});
