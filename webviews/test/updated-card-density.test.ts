// l10n-allow-file: test fixtures.
// Lawrence 2026-11-01 (msg 19498): "the card must reflect my compactness level". The sidebar's
// "Updated to Nightly" card drew fixed sizes at every sidebar density (12 px padding, 13 px text,
// a 24 px button, a 12 px corner), so at Compact it towered over the 24 pt rows. The host sends the
// sidebar's row tokens for the card as `--cmux-sidebar-card-*` (WebTheme, SidebarCardMetrics in
// Swift); the card's padding, text, button and corner are those, so at Compact it is about as
// tight as a row and Comfortable gives it the comfortable rows' room. Since Leo 2026-11-07 ("it
// becomes the exact same height as the composer") the card's box is the composer's one-line box at
// every density (48, two compact rows); its words still take the density's sizes.
// u51892 (2026-11-23): "the stuff in this message box is now just cut off for some reason, we need to elongate
// it according to how much content there is. we need to show everything". The 48 is now the card's least
// height: the change line wraps and the card grows to hold every line, with no glyph clipped.
//
// The real stylesheets and the real component (bundled) in Chromium and WebKit, under each density's
// variables exactly as SidebarCardMetricsTests expects the host to send them at page zoom 1.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

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
    "ui/glass/composerMaterial.css",
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
       flushSync(() => root.render(createElement(UpdatedCard, { data, shape: "two-line", strings: createStrings(table), actions, closeButton: false, glass: false } as any)));
     };`,
  );
  const built = await Bun.build({
    entrypoints: [entry],
    target: "browser",
    format: "iife",
    // A classic script has no import.meta: modules the card reaches (toolMentions.ts, #53425) read import.meta.url.
    define: { "import.meta.url": JSON.stringify("http://127.0.0.1/") },
  });
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
    // WebKit runs where it launches; where it cannot and the lane is not required, it skips (probeEngineOrSkip).
    ...((await probeEngineOrSkip("updated-card-density webkit", "webkit", webkit))
      ? [["webkit", webkit] as [string, BrowserType]]
      : []),
  ];
  for (const [name, engine] of engines) {
    describe(name, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      async function measure(density: keyof typeof DENSITIES, card = data, width = 244) {
        const page = await browser.newPage({ viewport: { width: 300, height: 300 } });
        await page.setContent(
          `<!doctype html><html style="${variables(DENSITIES[density])}"><head><style>${css}</style></head><body><div id="root" style="width:${width}px"></div></body></html>`,
        );
        await page.addScriptTag({ content: script });
        await page.evaluate((d) => (window as any).mount(d), card);
        const metrics = await page.evaluate(() => {
          const px = (value: string) => Number.parseFloat(value);
          const card = document.querySelector<HTMLElement>(".wn-card")!;
          const style = getComputedStyle(card);
          const title = getComputedStyle(document.querySelector(".wn-card-title")!);
          const note = getComputedStyle(document.querySelector(".wn-card-note")!);
          // Every glyph line's box (ascent to descent) inside every box that clips it: the card's, and any
          // of its words' own boxes that clip on the block axis. A line cut at its trimmed baseline fails.
          const box = card.getBoundingClientRect();
          const cut: string[] = [];
          for (const element of [document.querySelector(".wn-card-title")!, document.querySelector(".wn-card-note")!]) {
            const range = document.createRange();
            range.selectNodeContents(element);
            for (const line of Array.from(range.getClientRects())) {
              if (line.height === 0) continue;
              for (let clip: Element | null = element; clip && clip !== card.parentElement; clip = clip.parentElement) {
                const overflowY = getComputedStyle(clip).overflowY;
                if (overflowY === "visible") continue;
                const edge = clip.getBoundingClientRect();
                if (line.top < edge.top - 0.5 || line.bottom > edge.bottom + 0.5) {
                  cut.push(
                    `${element.className} line ${line.top}-${line.bottom} cut by ${clip.className} ${edge.top}-${edge.bottom}`,
                  );
                }
              }
            }
          }
          const lines = (element: Element) => {
            const range = document.createRange();
            range.selectNodeContents(element);
            return new Set(
              Array.from(range.getClientRects())
                .filter((r) => r.height > 0)
                .map((r) => Math.round(r.top)),
            ).size;
          };
          const noteBox = document.querySelector(".wn-card-note")!.getBoundingClientRect();
          return {
            radius: px(style.borderTopLeftRadius),
            title: px(title.fontSize),
            note: px(note.fontSize),
            height: box.height,
            noteLines: lines(document.querySelector(".wn-card-note")!),
            noteInside: noteBox.right <= box.right + 0.5,
            cut,
          };
        });
        await page.close();
        return metrics;
      }

      // The words follow the sidebar's density; the card's box is the composer's at every density
      // (Leo 2026-11-07: "it becomes the exact same height as the composer"): grid.md 5.1's one-line
      // box (48), at least, and the composer's corner.
      for (const density of Object.keys(DENSITIES) as (keyof typeof DENSITIES)[]) {
        test(`at ${density} the card's words take the sidebar rows' tokens and its box is the composer's`, async () => {
          const want = DENSITIES[density];
          const got = await measure(density);
          expect(got.title).toBe(want.title);
          expect(got.note).toBe(want.note);
          expect(got.height).toBe(48);
          // The composer's own corner: the card is its twin (Lawrence 2026-11-23, back to the original look).
          expect(got.radius).toBe(16);
          expect(got.cut).toEqual([]);
        });

        // u51892: a change line longer than the card wraps, and the card grows to show all of it.
        test(`at ${density} a long change wraps and the card grows to show every line in full`, async () => {
          const long = {
            ...data,
            items: [
              {
                id: "a",
                // Longer than its first clause: the card shows it whole (updateSummary.ts `full`).
                title: "Fix the glass on the settings panels, so toggles read on bright wallpapers",
                summary: null,
                category: "fixed",
              },
            ],
          };
          // A narrow sidebar's card: the line cannot fit on one row.
          const got = await measure(density, long, 180);
          expect(got.noteLines).toBeGreaterThan(1);
          expect(got.height).toBeGreaterThan(48);
          expect(got.noteInside).toBe(true);
          expect(got.cut).toEqual([]);
        });
      }
    });
  }
});
