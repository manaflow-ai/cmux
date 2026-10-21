// The code editor's find pill in a narrow pane: it wants about 390px, so in a 360px editor it must
// shrink inside the pane (its fields give way) instead of running off the left edge, where the
// gallery showed it cut at x≈-39 with the placeholder read as "place". Every control stays inside
// the pill too, in both modes: Cmd-F's one row and Replace's two.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { Icon, type IconName } from "../src/icons";
import { FindPill, type FindPillIconRole } from "../src/ui/FindPill";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("editor-find-narrow.test.tsx", async () => {
  setDefaultTimeout(60_000);
  const icons = {
    search: "search",
    previous: "chevronUp",
    next: "chevronDown",
    close: "close",
  } as const satisfies Record<FindPillIconRole, IconName>;
  const src = path.resolve(import.meta.dir, "../src");
  const css = ["ui/findPill.css", "pages/editor/styles.css"]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");

  // What EditorFindBar renders, in English. The bar itself reads its EditorFind through
  // useSyncExternalStore, which static rendering can't run.
  const none = () => undefined;
  const bar = (replaceOpen: boolean) =>
    renderToStaticMarkup(
      <div className="ed-find">
        <FindPill
          query="old"
          onQueryChange={none}
          status="1 of 2"
          noMatches={false}
          canStep
          onNext={none}
          onPrevious={none}
          onClose={none}
          matchCase={false}
          onMatchCaseChange={none}
          labels={{ placeholder: "Find", previous: "Previous", next: "Next", close: "Close", matchCase: "Match Case" }}
          icon={(role) => <Icon name={icons[role]} />}
          replace={{
            open: replaceOpen,
            value: "",
            onChange: none,
            onReplace: none,
            onReplaceAll: none,
            onToggle: none,
            labels: { field: "Replace", replace: "Replace", replaceAll: "All", toggle: "Toggle Replace" },
          }}
        />
      </div>,
    );

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  describe("editor find pill", () => {
    for (const replaceOpen of [false, true])
      for (const width of [360, 300]) {
        test(`stays inside a ${width}px editor, replace ${replaceOpen ? "open" : "closed"}`, async () => {
          const page = await browser.newPage({ viewport: { width, height: 200 } });
          await page.setContent(
            `<style>${css} body { margin: 0 }</style><div class="ed-frame" style="height: 200px">${bar(replaceOpen)}</div>`,
          );
          const boxes = await page.evaluate(() => {
            const rect = (el: Element) => {
              const r = el.getBoundingClientRect();
              return { name: el.getAttribute("aria-label") ?? el.className, left: r.left, right: r.right };
            };
            const pill = document.querySelector(".find-pill")!;
            return { pill: rect(pill), controls: [...pill.querySelectorAll("button, input")].map(rect) };
          });
          await page.close();
          expect(boxes.pill.left).toBeGreaterThanOrEqual(10);
          expect(boxes.pill.right).toBeLessThanOrEqual(width - 10);
          const outside = boxes.controls.filter((c) => c.left < boxes.pill.left || c.right > boxes.pill.right);
          expect(outside).toEqual([]);
        });
      }
  });
});
