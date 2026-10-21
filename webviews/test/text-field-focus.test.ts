// A focused text field never draws a ring of its own (cx-ncc.57). A text field is :focus-visible on
// every focus, mouse included, and its box is a plain rectangle inside the rounded control that
// owns it, so a ring drew a square inside the composer, the New Tab box and the model picker's
// search. The caret shows focus instead: the composer and the New Tab box draw no focus ring
// either (Leo 2026-10-19: the focus ring flashed).
//
// The gallery plays the named surfaces and the pages with text fields on the real dev server (the
// same frames the matrix renders) in WebKit, the engine the app's pages run in, in a light and a
// dark theme. On each stage every visible text field (inputs, textareas, contenteditable prompts,
// also inside open shadow roots) takes focus; its computed outline must be none. On the surfaces
// Lawrence named, focus must still show: the focused field draws its caret, so keyboard users
// still see where focus is.
//
// The engine comes from `playwright install webkit`; where it is not installed, the cases are
// skipped and say so.
//
// Starting Vite, warming the named surfaces' frames and 22 page loads took about 90 s on a busy Huge
// Blue; warming the whole gallery (about 2,300 modules) instead took 170 s there and 115 s on the CI
// runner (run-webviews-tests.sh):
// cmux-web-test-timeout: 240
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import fs from "node:fs";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { loadEntries } from "../scripts/gallery/entries";
import { stopDevServer } from "./support/devServer";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("text-field-focus.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");

  // WebKit first (the app's pages run in WKWebView); Chromium where WebKit is not installed.
  let engine: BrowserType | null = null;
  for (const [name, candidate] of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as [string, BrowserType][]) {
    try {
      await (await candidate.launch({ headless: true })).close();
      engine = candidate;
      break;
    } catch {
      console.warn(`text-field-focus: ${name} is not installed (run \`bunx playwright install ${name}\`)`);
    }
  }
  const installed = engine !== null;
  // Proof captures: with CMUX_TEXT_FOCUS_SHOTS=<dir>, each named surface's first field is shot
  // unfocused and focused (the before/after page of cx-ncc.57).
  const shots = process.env.CMUX_TEXT_FOCUS_SHOTS;

  // The surfaces Lawrence named, in the whole agent pane (its real stylesheet, Tailwind included):
  // the composer, the composer with its model picker open on the search, and New Tab. Each must
  // mount, have a field, and show focus on an ancestor. Then the other surfaces and pages with text
  // fields, for the ring alone (the model picker's own entry is a bare component without the pane's
  // Tailwind sheet). The first variant of each; the CSS lint
  // (scripts/cmux-next/check-text-focus-rings.py) guards the rest statically.
  type Case = { entry: string; variant?: string; open?: string; field?: string; named: boolean };
  const NAMED: Case[] = [
    { entry: "agent-pane.composer", named: true },
    { entry: "agent-pane.composer", open: "Model", field: 'input[type="search"]', named: true },
    { entry: "agent-pane.new-tab", named: true },
  ];
  const OTHERS = [
    "agent-pane.model-picker",
    "agent-pane.add-project-panel",
    "agent-pane.chat-find-bar",
    "pages.settings",
    "pages.debug-settings",
    "pages.history",
    "pages.keybindings",
    "pages.cloud",
  ];
  const THEMES = [
    { theme: "Apple System Colors Light", colorScheme: "light" },
    { theme: "Apple System Colors", colorScheme: "dark" },
  ];
  const entries = new Map((await loadEntries()).map((entry) => [entry.id, entry]));
  const cases = [...NAMED, ...OTHERS.map((entry): Case => ({ entry, named: false }))]
    .filter((item) => entries.has(item.entry))
    .map((item) => ({ ...item, variant: item.variant ?? Object.keys(entries.get(item.entry)!.variants)[0]! }));

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
    // The named surfaces only: the others may fail to mount, which their tests tolerate (below).
    await warmGalleryFrame(base, [...new Set(cases.filter(({ named }) => named).map(({ entry }) => entry))], {
      browser,
      // Under the file's 240 s limit, so a stalled warm-up fails here, naming its entry.
      timeoutMs: 150_000,
    });
  }, 200_000);

  afterAll(async () => {
    await browser?.close();
    stopDevServer(server);
  });

  type FieldReport = { field: string; ring: string; shown: boolean };

  /** Focuses every visible text field on the stage; reports its outline and whether it draws its caret. */
  async function focusEveryField(page: Page, only?: string): Promise<FieldReport[]> {
    return page.evaluate((only) => {
      const TEXT =
        'input:not([type="button"], [type="submit"], [type="reset"], [type="checkbox"], [type="radio"], [type="range"], [type="color"], [type="file"], [type="image"], [type="hidden"]), textarea, [contenteditable]:not([contenteditable="false"])';
      const roots: (Document | ShadowRoot)[] = [document];
      for (const host of document.querySelectorAll("*")) if (host.shadowRoot) roots.push(host.shadowRoot);
      const fields = roots
        .flatMap((root) => [...root.querySelectorAll<HTMLElement>(TEXT)])
        .filter((field) => {
          // An open popover's field alone: focusing another field would close it first.
          if (only && !field.matches(only)) return false;
          // A contenteditable child of an editable host is part of that field, not a field of its own.
          if (field.parentElement?.closest('[contenteditable]:not([contenteditable="false"])')) return false;
          const rect = field.getBoundingClientRect();
          const style = getComputedStyle(field);
          return (
            rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && !(field as HTMLInputElement).disabled
          );
        });
      const describe = (field: HTMLElement) =>
        `${field.tagName.toLowerCase()}${field.className && typeof field.className === "string" ? `.${field.className.trim().split(/\s+/).join(".")}` : ""}[${field.getAttribute("aria-label") ?? field.getAttribute("placeholder") ?? ""}]`;
      const reports: FieldReport[] = [];
      for (const field of fields) {
        if (!field.isConnected) continue;
        field.focus();
        const active =
          field.getRootNode() instanceof ShadowRoot
            ? (field.getRootNode() as ShadowRoot).activeElement
            : document.activeElement;
        if (active !== field) continue;
        const style = getComputedStyle(field);
        const ring =
          style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0
            ? `${style.outlineStyle} ${style.outlineWidth} ${style.outlineColor}`
            : "";
        // Focus shows as the caret: the composer and the New Tab box look the same focused or not.
        const caret = style.caretColor !== "transparent" && style.caretColor !== "rgba(0, 0, 0, 0)";
        field.blur();
        // A popover that closes when its field loses focus shows focus by being open.
        const shown = !field.isConnected || caret;
        reports.push({ field: describe(field), ring, shown });
      }
      return reports;
    }, only);
  }

  /** Shoots the first text field's box unfocused and focused, cropped around the field. */
  async function shoot(page: Page, prefix: string, selector?: string) {
    const field = page
      .locator(
        selector ?? 'textarea, [contenteditable="true"], input[type="search"], input[type="text"], input:not([type])',
      )
      .first();
    if ((await field.count()) === 0) return;
    const box = await field.boundingBox();
    if (!box) return;
    const clip = {
      x: Math.max(0, box.x - 48),
      y: Math.max(0, box.y - 40),
      width: Math.min(960, box.width + 96),
      height: box.height + 80,
    };
    fs.mkdirSync(path.dirname(prefix), { recursive: true });
    // Focused first: a popover's search closes when it loses focus.
    await field.evaluate((node) => (node as HTMLElement).focus());
    await page.screenshot({ path: `${prefix}--focused.png`, clip });
    await field.evaluate((node) => (node as HTMLElement).blur());
    await page.screenshot({ path: `${prefix}--unfocused.png`, clip });
  }

  describe("text fields draw no focus ring of their own", () => {
    for (const { entry, variant, open, field, named } of cases)
      for (const { theme, colorScheme } of THEMES)
        // No engine: skipped, never a vacuous pass (CI fails the file first, requireBrowserLane).
        test.skipIf(!installed)(`${entry} / ${variant}${open ? ` / ${open} open` : ""} (${colorScheme})`, async () => {
          if (!browser) throw new Error("text-field-focus: the browser did not launch");
          const page = await browser.newPage({ viewport: { width: 1000, height: 760 } });
          try {
            await page.goto(
              `${base}${galleryFrame(entry, { variant, theme, colorScheme, frame: "component", width: "760", height: "640" })}`,
            );
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              null,
              {
                timeout: 120_000,
              },
            );
            const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
            // A named surface must mount; another stage that fails to mount is the gallery tests' finding.
            if (named) expect(ready).toBe("1");
            if (ready !== "1") return;
            if (open) {
              // The model button opens its compact menu (Leo 2026-10-20), which has no search; the
              // full picker with its search opens by its label, as automation and More models do.
              await page.evaluate(
                (label) =>
                  (
                    window as unknown as { cmuxAcpmuxDebug: { openMenu(label: string): Promise<unknown> } }
                  ).cmuxAcpmuxDebug.openMenu(label),
                open,
              );
              await page.locator(field!).first().waitFor({ state: "visible" });
            }
            const name = `${entry}--${variant}${open ? `--${open.toLowerCase()}-open` : ""}--${colorScheme}`;
            if (shots && named) await shoot(page, path.join(shots, name), field);
            const reports = await focusEveryField(page, open ? field : undefined);
            expect(reports.filter((report) => report.ring).map(({ field, ring }) => `${field}: ${ring}`)).toEqual([]);
            if (named) {
              expect(reports.length).toBeGreaterThan(0);
              expect(
                reports.filter((report) => !report.shown).map(({ field }) => `${field}: no visible focus state`),
              ).toEqual([]);
            }
          } finally {
            await page.close();
          }
        });
  });
});
