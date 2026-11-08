// l10n-allow-file: test fixtures.
// Lawrence 2026-11-07, on the Updated card's open hover preview: "this ui is very bad". Every line was
// cut with an ellipsis (each change's title, "Updated to ..." with no version, the top change), What's
// New floated after the cut title, and the last row was dimmed. In the sidebar card's width the open
// card reads whole: a header first (the title line, the full version, What's New), then the changes,
// each title wrapping instead of being cut, and no row faded.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("updated-card-preview-reads-whole.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "ui/glass/glass.css",
    "ui/glass/composerMaterial.css",
    "pages/shared/pageBase.css",
    "pages/changelog/updateSurfaces.css",
    "pages/changelog/surface.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");

  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".updated-card-whole-"));
  const entry = path.join(dir, "entry.tsx");
  fs.writeFileSync(
    entry,
    `import { createElement } from "react";
     import { flushSync } from "react-dom";
     import { createRoot } from "react-dom/client";
     import { UpdatedCard } from ${JSON.stringify(path.join(source, "pages/changelog/UpdateSurfaces.tsx"))};
     import { createStrings } from ${JSON.stringify(path.join(source, "pages/shared/i18n.ts"))};
     import table from ${JSON.stringify(path.join(source, "pages/changelog/generated/strings.json"))};
     (window as any).mount = (data: unknown) => {
       const root = createRoot(document.getElementById("root")!);
       const props: any = { data, strings: createStrings(table), actions: { openChangelog() {}, dismiss() {} },
         closeButton: false, glass: false, previewOpen: true, previewMode: "above" };
       flushSync(() => root.render(createElement(UpdatedCard, props)));
     };`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  fs.rmSync(dir, { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();

  // The changes of Lawrence's shot, as the host sends them.
  const data = {
    version: "1.0.0-nightly.4241815985601",
    build: "4241815985601",
    fromVersion: "1.0.0-nightly.4230000000001",
    fromBuild: "4230000000001",
    source: "whatsNew",
    language: "en",
    items: [
      { id: "dictation", title: "Show when another app is dictating into a chat", summary: null, category: "new" },
      {
        id: "new-tab",
        title: "New Browser Tab always opens a blank page beside the current one",
        summary: null,
        category: "improved",
      },
      { id: "tool-calls", title: "Show grouped tool calls as an iOS-style stack", summary: null, category: "improved" },
    ],
    moreCount: 0,
    changelog: { from: "1.0.0-nightly.4230000000001", to: "1.0.0-nightly.4241815985601" },
  };
  const themes = {
    dark: "color-scheme:dark;--cmux-surface-background:#1e1e1e;--cmux-surface-solid:#1e1e1e;--cmux-text:#ddd",
    light: "color-scheme:light;--cmux-surface-background:#fff;--cmux-surface-solid:#fff;--cmux-text:#24292f",
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

      async function open(look: keyof typeof themes): Promise<Page> {
        // The sidebar's card at its default width (a 260 pt sidebar less its 12 pt insets).
        const page = await browser.newPage({ viewport: { width: 236, height: 480 } });
        await page.setContent(
          `<!doctype html><html data-surface="updated" data-glass="plain" data-cmux-motion="off" style="${themes[look]}"><head><meta charset="utf-8"><style>${css}</style></head>` +
            `<body style="margin:0"><div id="root"></div></body></html>`,
        );
        await page.addScriptTag({ content: script });
        await page.evaluate((d) => (window as any).mount(d), data);
        await page.waitForSelector('.wn-updated[data-preview="open"]');
        return page;
      }

      for (const look of ["light", "dark"] as const) {
        test(`the open card cuts no line of the header or of a change (${look})`, async () => {
          const page = await open(look);
          const got = await page.evaluate(() => {
            const cut = (element: Element | null) =>
              !!element &&
              (element.scrollWidth > element.clientWidth + 1 || element.scrollHeight > element.clientHeight + 1);
            const text = (selector: string) => document.querySelector(selector)?.textContent ?? "";
            const top = (selector: string) => document.querySelector(selector)?.getBoundingClientRect().top ?? NaN;
            const list = document.querySelector(".wn-preview-list")!;
            const listStyle = getComputedStyle(list) as unknown as Record<string, string>;
            return {
              title: text(".wn-card-title"),
              titleCut: cut(document.querySelector(".wn-card-title")),
              version: text(".wn-card-version"),
              versionCut: cut(document.querySelector(".wn-card-version")),
              cutChanges: [...document.querySelectorAll(".wn-preview-title")].filter(cut).map((t) => t.textContent),
              changes: document.querySelectorAll(".wn-preview-title").length,
              whatsNew: text(".wn-preview-whatsnew"),
              headerAboveChanges: top(".wn-card-title") < top(".wn-preview-list"),
              whatsNewAboveChanges: top(".wn-preview-whatsnew") < top(".wn-preview-list"),
              mask: listStyle.webkitMaskImage || listStyle.maskImage || "none",
            };
          });
          expect(got.title).toContain("Nightly");
          expect(got.titleCut).toBe(false);
          expect(got.version).toBe("1.0.0-nightly.4241815985601");
          expect(got.versionCut).toBe(false);
          expect(got.changes).toBe(3);
          expect(got.cutChanges).toEqual([]);
          expect(got.whatsNew).toContain("What's New");
          expect(got.headerAboveChanges).toBe(true);
          expect(got.whatsNewAboveChanges).toBe(true);
          // More rows show the scrollbar; no row is faded.
          expect(got.mask).toBe("none");
          await page.close();
        });
      }
    });
  }
});
