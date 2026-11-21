// l10n-allow-file: test fixtures.
// Lawrence 2026-11-07, on the sidebar's "Updated to … · What's New ↗ / Maintenance and fixes" card:
// "feels like too much padding on top". The card's two lines sat centred in the composer's 48 px box
// with their line boxes' leading, so the room above the title's capitals and below the note's baseline
// did not match each other or the card's side inset. Each line is trimmed to its capitals and its
// baseline, and the lines stand the side inset in from the card's top and bottom: the text has the
// same room on all four sides, at every density, and the box stays the composer's.
//
// The real stylesheets and the real component (bundled) in Chromium and WebKit (CI's browser lane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("updated-card-even-insets.test.ts", async () => {
  setDefaultTimeout(120_000);
  /** What the host sends per sidebar density (SidebarCardMetricsTests: the app's compact tokens). */
  const DENSITIES = {
    compact: {
      paddingX: 6,
      paddingY: 4,
      gap: 2,
      radius: 10,
      title: 12,
      note: 10.5,
      button: 20,
      buttonPaddingX: 6,
      buttonRadius: 6,
    },
    comfortable: {
      paddingX: 8,
      paddingY: 6,
      gap: 4,
      radius: 12,
      title: 12,
      note: 10.5,
      button: 24,
      buttonPaddingX: 8,
      buttonRadius: 6,
    },
  } as const;

  function variables(d: (typeof DENSITIES)[keyof typeof DENSITIES]): string {
    return [
      `--cmux-sidebar-card-padding-x:${d.paddingX}px`,
      `--cmux-sidebar-card-padding-y:${d.paddingY}px`,
      `--cmux-sidebar-card-gap:${d.gap}px`,
      `--cmux-sidebar-card-radius:${d.radius}px`,
      `--cmux-sidebar-card-title:${d.title}px`,
      `--cmux-sidebar-card-note:${d.note}px`,
      `--cmux-sidebar-card-button:${d.button}px`,
      `--cmux-sidebar-card-button-padding-x:${d.buttonPaddingX}px`,
      `--cmux-sidebar-card-button-radius:${d.buttonRadius}px`,
    ].join(";");
  }

  const source = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "pages/shared/pageBase.css",
    "ui/glass/composerMaterial.css",
    "pages/changelog/updateSurfaces.css",
    "pages/changelog/surface.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".updated-card-even-insets-"));
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
       const actions = { openChangelog: () => undefined, dismiss: () => undefined };
       // As the sidebar mounts it (surface.tsx): the host draws the glass and the x.
       flushSync(() => root.render(createElement(UpdatedCard, { data, strings: createStrings(table), actions, closeButton: false, glass: false } as any)));
     };`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser", format: "iife" });
  fs.rmSync(dir, { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const output = built.outputs.find((artifact) => artifact.kind === "entry-point" && artifact.path.endsWith(".js"));
  if (!output) throw new Error("no script in the bundle");
  const script = await output.text();
  const data = {
    version: "1.0.0-nightly.4124615690001",
    build: "4124615690001",
    date: "2026-10-31",
    source: "whatsNew",
    language: "en",
    items: [],
    moreCount: 0,
    changelog: { from: "1.0.0-nightly.4037004604601", to: "1.0.0-nightly.4124615690001" },
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

      for (const density of Object.keys(DENSITIES) as (keyof typeof DENSITIES)[]) {
        test(`at ${density} the card's text has the same room above, below and at the sides`, async () => {
          const page = await browser.newPage({ viewport: { width: 300, height: 300 } });
          await page.setContent(
            `<!doctype html><html style="${variables(DENSITIES[density])}"><head><style>${css}</style></head><body><div id="root" style="width:244px"></div></body></html>`,
          );
          await page.addScriptTag({ content: script });
          await page.evaluate((d) => (window as any).mount(d), data);
          const got = await page.evaluate(() => {
            const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
            const card = rect(".wn-card");
            const title = rect(".wn-card-title");
            const note = rect(".wn-card-note");
            return {
              height: card.height,
              top: title.top - card.top,
              bottom: card.bottom - note.bottom,
              side: title.left - card.left,
            };
          });
          await page.close();
          expect(got.height).toBe(48);
          expect(
            Math.abs(got.top - got.side),
            `the room above the title's capitals: ${JSON.stringify(got)}`,
          ).toBeLessThanOrEqual(0.5);
          expect(
            Math.abs(got.bottom - got.side),
            `the room under the note's baseline: ${JSON.stringify(got)}`,
          ).toBeLessThanOrEqual(0.5);
        });
      }
    });
  }
});
