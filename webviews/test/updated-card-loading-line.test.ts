// l10n-allow-file: test fixtures.
// Leo 2026-11-09, on the sidebar's Updated card: "it should have the updated to Nightly already loaded
// in, instead of just having a blank glass bit ... for the, you know, fixed or whatever subtitle text
// individually, we can have it be, like, should have a loading indicator, like an ellipsis-type thing".
// The card draws its title from the host's data at once; while the update's notes load, its change
// line is a quiet indicator in the note's own box, one line tall, so the words that replace it move
// nothing: the card's height and the line's place are the same before and after, in every look of
// the indicator, with motion on or off, in light and dark.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("updated-card-loading-line.test.ts", async () => {
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

  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".updated-card-loading-"));
  const entry = path.join(dir, "entry.tsx");
  fs.writeFileSync(
    entry,
    `import { createElement } from "react";
     import { flushSync } from "react-dom";
     import { createRoot } from "react-dom/client";
     import { UpdatedCard } from ${JSON.stringify(path.join(source, "pages/changelog/UpdateSurfaces.tsx"))};
     import { createStrings } from ${JSON.stringify(path.join(source, "pages/shared/i18n.ts"))};
     import table from ${JSON.stringify(path.join(source, "pages/changelog/generated/strings.json"))};
     const root = createRoot(document.getElementById("root")!);
     (window as any).mount = (data: unknown, notesLoading: boolean, loadingLook: string, decoration: string | null = null) => {
       const props: any = { data, strings: createStrings(table), actions: { openChangelog() {}, dismiss() {} },
         closeButton: false, glass: false, previewOpen: false, notesLoading, loadingLook, decoration, animate: false };
       flushSync(() => root.render(createElement(UpdatedCard, props)));
     };`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  fs.rmSync(dir, { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();

  // Leo's card: "Updated to Nightly", then "Fixed: lock horizontal scroll" once the notes are in.
  const data = {
    version: "1.0.0-nightly.4241815985601",
    build: "4241815985601",
    fromVersion: "1.0.0-nightly.4230000000001",
    fromBuild: "4230000000001",
    source: "whatsNew",
    language: "en",
    items: [{ id: "scroll", title: "Lock horizontal scroll", summary: null, category: "fixed" }],
    moreCount: 0,
    changelog: { from: "1.0.0-nightly.4230000000001", to: "1.0.0-nightly.4241815985601" },
  };
  const themes = {
    dark: "color-scheme:dark;--cmux-surface-background:#1e1e1e;--cmux-surface-solid:#1e1e1e;--cmux-text:#ddd",
    light: "color-scheme:light;--cmux-surface-background:#fff;--cmux-surface-solid:#fff;--cmux-text:#24292f",
  };
  const looks = ["dots", "glyph", "bar", "words"] as const;

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

      // Review F1 of #39934: the doodle card's change line wraps to two lines; its loading line keeps that
      // room, so a short or a long change takes its place at one height.
      test("the doodle card's loading line holds the change line's room, short or wrapping", async () => {
        const page = await browser.newPage({ viewport: { width: 236, height: 400 } });
        await page.setContent(
          `<!doctype html><html data-surface="updated" data-glass="plain" data-cmux-motion="off" style="${themes.dark}"><head><meta charset="utf-8"><style>${css}</style></head>` +
            `<body style="margin:0"><div id="root"></div></body></html>`,
        );
        await page.addScriptTag({ content: script });
        const wrapping = {
          ...data,
          items: [
            {
              id: "long",
              title: "Lock horizontal scroll in every transcript, diff and file view while a chat streams",
              summary: null,
              category: "fixed",
            },
          ],
        };
        const measure = () =>
          page.evaluate(() => {
            const card = document.querySelector('.wn-card[data-decoration="doodle"]')?.getBoundingClientRect();
            const note = document.querySelector(".wn-card-note")?.getBoundingClientRect();
            const style = getComputedStyle(document.querySelector(".wn-card-note")!);
            return {
              card: card?.height ?? NaN,
              note: note ? { top: note.top, height: note.height } : null,
              lines: note ? Math.round(note.height / Number.parseFloat(style.lineHeight)) : 0,
              loading: document.querySelector(".wn-card-note-loading") !== null,
            };
          });
        for (const [name, d] of [
          ["short", data],
          ["wrapping", wrapping],
        ] as const) {
          for (const look of looks) {
            await page.evaluate(([d, l]) => (window as any).mount(d, true, l, "doodle"), [d, look] as const);
            const loading = await measure();
            await page.evaluate(([d, l]) => (window as any).mount(d, false, l, "doodle"), [d, look] as const);
            const loaded = await measure();
            expect(loading.loading).toBe(true);
            expect(loaded.loading).toBe(false);
            expect({ name, look, card: loading.card, note: loading.note }).toEqual({
              name,
              look,
              card: loaded.card,
              note: loaded.note,
            });
          }
        }
        // The wrapping change really wraps: two lines, the room the loading line kept.
        await page.evaluate((d) => (window as any).mount(d, false, "dots", "doodle"), wrapping);
        expect((await measure()).lines).toBe(2);
        await page.close();
      });

      for (const theme of ["light", "dark"] as const) {
        for (const motion of ["on", "off"] as const) {
          test(`the loading line holds the change line's room in every look (${theme}, motion ${motion})`, async () => {
            // The sidebar's card at its default width (a 260 pt sidebar less its 12 pt insets).
            const page = await browser.newPage({ viewport: { width: 236, height: 200 } });
            await page.setContent(
              `<!doctype html><html data-surface="updated" data-glass="plain" data-cmux-motion="${motion}" style="${themes[theme]}"><head><meta charset="utf-8"><style>${css}</style></head>` +
                `<body style="margin:0"><div id="root"></div></body></html>`,
            );
            await page.addScriptTag({ content: script });
            const measure = () =>
              page.evaluate(() => {
                const rect = (selector: string) => {
                  const box = document.querySelector(selector)?.getBoundingClientRect();
                  return box ? { top: box.top, height: box.height } : null;
                };
                return {
                  title: document.querySelector(".wn-card-title")?.textContent ?? "",
                  card: rect(".wn-card"),
                  note: rect(".wn-card-note"),
                  loading: document.querySelector(".wn-card-note-loading") !== null,
                  noteText: document.querySelector(".wn-card-note")?.textContent ?? "",
                };
              });
            for (const look of looks) {
              await page.evaluate(([d, l]) => (window as any).mount(d, true, l), [data, look] as const);
              const loading = await measure();
              await page.evaluate(([d, l]) => (window as any).mount(d, false, l), [data, look] as const);
              const loaded = await measure();
              // The title is there while the notes load, the same as after.
              expect(loading.title).toContain("Updated to Nightly");
              expect(loaded.title).toBe(loading.title);
              expect(loading.loading).toBe(true);
              expect(loaded.loading).toBe(false);
              expect(loaded.noteText).toBe("Fixed: lock horizontal scroll");
              // The words swap in where the line was: nothing moves, nothing grows.
              expect({ look, ...loading.card }).toEqual({ look, ...loaded.card! });
              expect({ look, ...loading.note }).toEqual({ look, ...loaded.note! });
            }
            await page.close();
          });
        }
      }
    });
  }
});
