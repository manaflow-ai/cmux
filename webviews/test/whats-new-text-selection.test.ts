// l10n-allow-file: test fixtures.
// u4466 (2026-10-19): "i cant select text in what's new thing". The "cmux Updated!" sidebar card and
// the Update Ready hover card are their own small pages (surface.tsx) on the shared page base,
// whose body is `user-select: none` (desktop chrome). Their change titles and lines are text a
// person reads and quotes: a drag selects them, a double-click selects a word, and the selection is
// what Copy copies. Selecting never runs the card's buttons (See What's New, the x, See all changes),
// and those buttons still work on a click.
//
// The page is the real stylesheets and the real components (bundled) in Chromium and WebKit; the
// pointer is Playwright's mouse.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("whats-new-text-selection.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "pages/shared/pageBase.css",
    "pages/changelog/updateSurfaces.css",
    "pages/changelog/surface.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");

  // Inside webviews/ so the bundle resolves react from its node_modules.
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".whats-new-select-"));
  const entry = path.join(dir, "entry.tsx");
  fs.writeFileSync(
    entry,
    `import { createElement } from "react";
     import { flushSync } from "react-dom";
     import { createRoot } from "react-dom/client";
     import { UpdatedCard, UpdateReadyHighlights } from ${JSON.stringify(path.join(source, "pages/changelog/UpdateSurfaces.tsx"))};
     import { routeChipHost } from ${JSON.stringify(path.join(source, "pages/changelog/ChangePullRequest.tsx"))};
     import { languageDirection, UiProvider } from ${JSON.stringify(path.join(source, "ui/UiProvider.tsx"))};
     import { createStrings } from ${JSON.stringify(path.join(source, "pages/shared/i18n.ts"))};
     import table from ${JSON.stringify(path.join(source, "pages/changelog/generated/strings.json"))};
     const calls = { openChangelog: 0, dismiss: 0 };
     (window as any).calls = calls;
     // As surface.tsx's mountUpdateSurface mounts them (#28004): the PR chips' host routed (no
     // host here) and the card inside the page's UiProvider.
     (window as any).mount = (kind: "ready" | "updated", data: unknown) => {
       routeChipHost(null);
       document.documentElement.dataset.surface = kind;
       const actions = kind === "updated"
         ? { openChangelog: () => void calls.openChangelog++, dismiss: () => void calls.dismiss++ }
         : { openChangelog: () => void calls.openChangelog++ };
       const strings = createStrings(table);
       const container = document.getElementById("root")!;
       const root = createRoot(container);
       const card = createElement(kind === "ready" ? UpdateReadyHighlights : UpdatedCard, { data, strings, actions } as any);
       flushSync(() => root.render(createElement(UiProvider, { container, dir: languageDirection(strings.language), overlayPosition: "fixed" }, card)));
     };`,
  );
  // One function scope (iife): the page loads it as a classic script, whose top-level
  // declarations would be the window's. Since the PR chips (#28004), the bundle holds a library's
  // top-level `function addEventListener(target, type, listener, options)`, which then shadowed
  // window.addEventListener, so the pane strings' languagechange listener threw as the bundle
  // loaded and `mount` was never defined. The app loads its bundle as a module, which has no such
  // leak.
  const built = await Bun.build({ entrypoints: [entry], target: "browser", format: "iife" });
  fs.rmSync(dir, { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  // The chips also import stylesheets, which the build emits beside the script: take the script.
  const output = built.outputs.find((artifact) => artifact.kind === "entry-point" && artifact.path.endsWith(".js"));
  if (!output) throw new Error(`no script among ${built.outputs.map((artifact) => artifact.path).join(", ")}`);
  const script = await output.text();

  const data = {
    version: "1.0.0-nightly.3845050428001",
    build: "3845050428001",
    fromVersion: "1.0.0-nightly.3801702344901",
    fromBuild: "3801702344901",
    date: "2026-10-19",
    source: "whatsNew",
    language: "en",
    items: [
      {
        id: "groups",
        title: "Workspace groups at a glance",
        summary: "Headers match the rows they hold",
        category: "new",
      },
      { id: "scroll", title: "Tables scroll", summary: null, category: "improved" },
      {
        id: "long",
        title:
          "Workspace groups you can see at a glance, with colored labels, icons and pins that keep a group together across every window you open",
        summary: null,
        category: "new",
      },
    ],
    moreCount: 4,
    changelog: { from: "1.0.0-nightly.3801702344901", to: "1.0.0-nightly.3845050428001" },
  };

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    describe(name, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      async function open(kind: "ready" | "updated", width?: number): Promise<Page> {
        const page = await browser.newPage({ viewport: { width: 420, height: 400 } });
        await page.setContent(
          `<!doctype html><html style="--page-text:#ddd;--page-text-2:#aaa;--page-text-3:#888"><head><style>${css}</style></head><body><div id="root"${width ? ` style="width:${width}px"` : ""}></div></body></html>`,
        );
        // A bundle that throws as it loads defines no mount: name its error, not the missing mount.
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.stack ?? String(error)));
        await page.addScriptTag({ content: script });
        if (errors.length > 0) throw new Error(`the bundle threw as it loaded: ${errors.join("; ")}`);
        await page.evaluate(([k, d]) => (window as any).mount(k, d), [kind, data] as const);
        return page;
      }

      const selection = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");
      const calls = (page: Page) => page.evaluate(() => ({ ...(window as any).calls }));

      /** Drags across the element's text, left edge to right edge, on its middle line. */
      async function dragAcross(page: Page, selector: string) {
        const box = (await page.locator(selector).first().boundingBox())!;
        const y = box.y + box.height / 2;
        await page.mouse.move(box.x + 2, y);
        await page.mouse.down();
        await page.mouse.move(box.x + box.width / 2, y, { steps: 4 });
        await page.mouse.move(box.x + box.width - 2, y, { steps: 4 });
        await page.mouse.up();
      }

      test("the Updated card's changes select with a drag and a double-click, and fire nothing", async () => {
        const page = await open("updated");
        // One line per area (updateSummary.ts): "Sidebar: workspace groups at a glance; …", then
        // "Improved: tables scroll" (one line even at 244 px in DejaVu Sans, CI's fallback font).
        await dragAcross(page, ".wn-card-areas li:nth-child(2)");
        expect(await selection(page)).toContain("tables scroll");
        expect(await calls(page)).toEqual({ openChangelog: 0, dismiss: 0 });

        const word = page.locator(".wn-card-areas li .wn-card-phrases").nth(1);
        const box = (await word.boundingBox())!;
        await page.mouse.dblclick(box.x + 12, box.y + box.height / 2);
        expect((await selection(page)).trim()).toBe("tables");
        expect(await calls(page)).toEqual({ openChangelog: 0, dismiss: 0 });
        expect(await page.locator(".wn-card").count()).toBe(1);

        // Its eyebrow and the count of the rest are text too.
        // The eyebrow says "Nightly · Oct 19"; the raw build is only its tooltip (e98d3a1ad827).
        await dragAcross(page, ".wn-card-eyebrow");
        expect(await selection(page)).toContain("Oct 19");
        await page.close();
      });

      test("the Updated card's buttons still work on a click", async () => {
        const page = await open("updated");
        await page.locator(".wn-card-primary").click();
        await page.locator(".wn-card").hover();
        await page.locator(".wn-card-close").click();
        expect(await calls(page)).toEqual({ openChangelog: 1, dismiss: 1 });
        // A click on a button selects nothing.
        expect(await selection(page)).toBe("");
        await page.close();
      });

      // Design #2 "Readable" (u4466 follow-up: "improve design of that too"): in the sidebar's card
      // a change title wraps onto a second line instead of being cut with an ellipsis, so it can be
      // read and selected whole; a very long one stops at two lines.
      test("in a sidebar-wide card a long change wraps to two lines, never cut on one", async () => {
        const page = await open("updated", 244);
        const rows = page.locator(".wn-card-areas li");
        const metrics = (index: number) =>
          rows.nth(index).evaluate((li) => ({
            height: li.getBoundingClientRect().height,
            line: parseFloat(getComputedStyle(li).lineHeight),
          }));
        // The Sidebar line holds both workspace group changes; the Improved line is short.
        const long = await metrics(0);
        const short = await metrics(1);
        // One line for a short title; two lines (not one, not three) for the long one.
        expect(short.height).toBeLessThan(short.line * 1.5 + 4);
        expect(long.height).toBeGreaterThan(long.line * 1.5);
        expect(long.height).toBeLessThan(long.line * 2.5 + 4);
        await page.close();
      });

      test("the Update Ready hover card's titles and lines select, and See all changes still opens", async () => {
        const page = await open("ready");
        await dragAcross(page, ".wn-pop-item");
        expect(await selection(page)).toContain("groups at a");
        await dragAcross(page, ".wn-pop-line");
        expect(await selection(page)).toContain("match the rows");
        await dragAcross(page, ".wn-pop-from");
        expect(await selection(page)).toContain("3801702");
        expect(await calls(page)).toEqual({ openChangelog: 0, dismiss: 0 });
        await page.locator(".wn-pop-all").click();
        expect(await calls(page)).toEqual({ openChangelog: 1, dismiss: 0 });
        await page.close();
      });
    });
  }
});
