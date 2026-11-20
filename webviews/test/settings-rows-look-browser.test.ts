// cmux-web-test-timeout: 600
// Shared Links' and the Customization Library's rows sit in a `.card-busy` fieldset (cardWindow.ts
// cardBusy: display: contents, no role), so a change in flight disables their controls without drawing
// a row again. The fieldset has no box but is still the rows' parent, so the cards' child-combinator
// rules missed them: `.rows > .row:first-child` / `:last-child` (layout.css: the card's corner radii,
// the last row's divider dropped) and `.rows > .row:not(:first-child)` (look.css: the hairline between
// rows). Idle, Shared Links lost its top corners, both cards' last rows their bottom corners and kept a
// divider under the card's edge, and in the refined look no row drew its hairline.
//
// A production build of test/browser/settings-cards-visible-only.html (the real page over the mock
// host) with 200 rows, in Chromium and WebKit, in each look: layout.css alone (no look), the refined
// look, and the refined look with Borders: None. Each card's first, a middle and its last row must
// draw what the same rows draw straight in a plain `.rows` list placed in the same card: corners,
// divider shadow and hairline. The last row is read once the page is scrolled to the card's end.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/settings-rows-look-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

type RowLook = { radius: string; shadow: string; line: string };
type Read = { first: RowLook; middle: RowLook; last: RowLook | null; lastIndex: number };

await requireBrowserLane("settings-rows-look-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines = [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const;
  const runs: (readonly [string, typeof chromium])[] = [];
  for (const [name, engine] of engines)
    if (await probeEngineOrSkip(`settings-rows-look-browser ${name}`, name, engine)) runs.push([name, engine]);
  let served: BenchPage;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    // `bun test` runs with NODE_ENV=test, and Vite's JSX transform follows it: the page is built as a
    // user runs it, with production React.
    const nodeEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/settings-cards-visible-only.html");
    } finally {
      process.env.NODE_ENV = nodeEnv;
    }
    for (const [name, engine] of runs) browsers.set(name, await engine.launch({ headless: true }));
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await served?.close();
  });

  const N = 200;
  const cards = [
    { card: "shares", name: "sharedLinks" },
    { card: "library", name: "customizeLibrary" },
  ] as const;
  // How the page picks a look: the refined look is `data-settings-look` on the root (mount.tsx; the
  // harness sets it), Borders: None is `data-borders`.
  const looks = [
    { look: "layout.css alone", settingsLook: null, borders: null },
    { look: "refined", settingsLook: "refined", borders: null },
    { look: "refined, Borders: None", settingsLook: "refined", borders: "none" },
  ] as const;

  /** Scrolls the page so the card's top (`end` false) or its end is in view, and waits for 10 painted
   * frames in a row with the same scroll and mounted rows. */
  const scrollCard = (page: Page, name: string, end: boolean) =>
    page.evaluate(
      ({ name, end }) =>
        new Promise<void>((resolve) => {
          const scroller = document.querySelector<HTMLElement>("main.content")!;
          const card = document.querySelector<HTMLElement>(`[data-card="${name}"]`)!;
          let last = "";
          let same = 0;
          window.cmuxAfterPaint(() => {
            const top = card.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
            // Again each frame: rows measured as they mount move the card's end.
            const want = end ? top + card.offsetHeight - scroller.clientHeight + 20 : top - 20;
            if (
              Math.abs(scroller.scrollTop - want) > 1 &&
              scroller.scrollTop < scroller.scrollHeight - scroller.clientHeight
            )
              scroller.scrollTop = want;
            const place = `${scroller.scrollTop}|${card.querySelectorAll("[data-index]").length}`;
            same = place === last ? same + 1 : 0;
            last = place;
            if (same < 10) return true;
            resolve();
            return false;
          });
        }),
      { name, end },
    );

  /** The card's first row, a middle one and its last mounted row, next to what a plain list of three
   * rows in the same card draws for its first, middle and last row. */
  const readRows = (page: Page, name: string) =>
    page.evaluate((name) => {
      const card = document.querySelector<HTMLElement>(`[data-card="${name}"]`)!;
      const look = (row: Element): RowLook => {
        const style = getComputedStyle(row);
        return {
          radius: [
            style.borderTopLeftRadius,
            style.borderTopRightRadius,
            style.borderBottomRightRadius,
            style.borderBottomLeftRadius,
          ].join(" "),
          shadow: style.boxShadow,
          line: style.backgroundImage,
        };
      };
      const plain = document.createElement("div");
      plain.className = "rows";
      plain.setAttribute("aria-hidden", "true");
      for (let at = 0; at < 3; at++) plain.append(Object.assign(document.createElement("div"), { className: "row" }));
      card.append(plain);
      const reference = [...plain.children].map(look);
      plain.remove();
      const rows = [...card.querySelectorAll<HTMLElement>(".rows .row")];
      const last = rows.at(-1)!;
      return {
        reference: { first: reference[0]!, middle: reference[1]!, last: reference[2]! },
        read: {
          first: look(rows[0]!),
          middle: look(rows[Math.floor(rows.length / 2)]!),
          last: look(last),
          lastIndex: Number(last.dataset.index ?? -1),
        } satisfies Read,
      };
    }, name);

  for (const [engine] of runs) {
    for (const { card, name } of cards) {
      for (const { look, settingsLook, borders } of looks) {
        test(`${engine}: ${name}, ${look}: an idle card's rows in the busy fieldset draw the corners, divider and hairline of a plain list's`, async () => {
          const page = await browsers.get(engine)!.newPage({ viewport: { width: 1200, height: 800 } });
          try {
            await installPaintedFrames(page);
            await gotoBenchPage(page, { ...served, url: `${served.url}#card=${card}&n=${N}` });
            await requireProductionReact(page, { dev: served.dev });
            await page.waitForFunction(
              (name) =>
                (window as { benchReady?: boolean }).benchReady === true &&
                !!document.querySelector(`[data-card="${name}"] [data-index]`),
              name,
            );
            await page.evaluate(
              ({ settingsLook, borders }) => {
                const root = document.documentElement;
                if (settingsLook) root.dataset.settingsLook = settingsLook;
                else delete root.dataset.settingsLook;
                if (borders) root.dataset.borders = borders;
                else delete root.dataset.borders;
              },
              { settingsLook, borders },
            );
            // Idle: no change in flight, so the fieldset is not disabled.
            expect(
              await page.evaluate(
                (name) =>
                  [...document.querySelectorAll(`[data-card="${name}"] fieldset.card-busy`)].map(
                    (one) => (one as HTMLFieldSetElement).disabled,
                  ),
                name,
              ),
            ).toEqual([false]);

            await scrollCard(page, name, false);
            const top = await readRows(page, name);
            expect(top.read.first).toEqual(top.reference.first);
            expect(top.read.middle).toEqual(top.reference.middle);

            await scrollCard(page, name, true);
            const end = await readRows(page, name);
            expect(end.read.lastIndex).toBe(N - 1);
            expect(end.read.last).toEqual(end.reference.last);
            expect(end.read.middle).toEqual(end.reference.middle);
            expect(end.read.first).toEqual(end.reference.first);
          } finally {
            await page.close();
          }
        });
      }
    }
  }
});
