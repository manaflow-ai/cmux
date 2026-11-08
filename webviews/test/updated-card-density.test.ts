// l10n-allow-file: test fixtures.
// Lawrence 2026-11-01 (msg 19498): "the card must reflect my compactness level". The sidebar's
// "Updated to Nightly" card drew fixed sizes at every sidebar density (12 px padding, 13 px text,
// a 24 px button, a 12 px corner), so at Compact it towered over the 24 pt rows. The host sends the
// sidebar's row tokens for the card as `--cmux-sidebar-card-*` (WebTheme, SidebarCardMetrics in
// Swift); the card's padding, text, button and corner are those, so at Compact it is about as
// tight as a row and Comfortable gives it the comfortable rows' room.
//
// The real stylesheets and the real component (bundled) in Chromium and WebKit, under each density's
// variables exactly as SidebarCardMetricsTests expects the host to send them at page zoom 1.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("updated-card-density.test.ts", async () => {
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
    "pages/changelog/updateSurfaces.css",
    "pages/changelog/surface.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".updated-card-density-"));
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
    items: [{ id: "a", title: "Each machine shows its cost", summary: null, category: "new" }],
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

      async function measure(density: keyof typeof DENSITIES) {
        const page = await browser.newPage({ viewport: { width: 300, height: 300 } });
        await page.setContent(
          `<!doctype html><html style="${variables(DENSITIES[density])}"><head><style>${css}</style></head><body><div id="root" style="width:244px"></div></body></html>`,
        );
        await page.addScriptTag({ content: script });
        await page.evaluate((d) => (window as any).mount(d), data);
        const metrics = await page.evaluate(() => {
          const px = (value: string) => Number.parseFloat(value);
          const card = document.querySelector<HTMLElement>(".wn-card")!;
          const style = getComputedStyle(card);
          const title = getComputedStyle(document.querySelector(".wn-card-title")!);
          const note = getComputedStyle(document.querySelector(".wn-card-note")!);
          const button = document.querySelector<HTMLElement>(".wn-card-primary")!;
          const buttonStyle = getComputedStyle(button);
          return {
            paddingX: px(style.paddingLeft),
            paddingY: px(style.paddingTop),
            radius: px(style.borderTopLeftRadius),
            title: px(title.fontSize),
            note: px(note.fontSize),
            button: button.getBoundingClientRect().height,
            buttonPaddingX: px(buttonStyle.paddingLeft),
            buttonRadius: px(buttonStyle.borderTopLeftRadius),
            height: card.getBoundingClientRect().height,
          };
        });
        await page.close();
        return metrics;
      }

      for (const density of Object.keys(DENSITIES) as (keyof typeof DENSITIES)[]) {
        test(`at ${density} the card takes the sidebar rows' tokens`, async () => {
          const want = DENSITIES[density];
          const got = await measure(density);
          expect(got.paddingX).toBe(want.paddingX);
          expect(got.paddingY).toBe(want.paddingY);
          expect(got.radius).toBe(want.radius);
          expect(got.title).toBe(want.title);
          expect(got.note).toBe(want.note);
          expect(got.button).toBe(want.button);
          expect(got.buttonPaddingX).toBe(want.buttonPaddingX);
          expect(got.buttonRadius).toBe(want.buttonRadius);
        });
      }

      // A title, one note line and the button: at Compact the whole card is under three 24 pt rows.
      test("a compact card is shorter than a comfortable one, and under three compact rows", async () => {
        const compact = await measure("compact");
        const comfortable = await measure("comfortable");
        expect(compact.height).toBeLessThan(comfortable.height);
        expect(compact.height).toBeLessThanOrEqual(3 * 24);
      });
    });
  }
});
