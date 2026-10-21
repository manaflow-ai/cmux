// The code editor's find pill in a narrow pane: with the replace row open it is wider than a 360px
// editor, and it must shrink inside the pane (its fields give way) instead of running off the left
// edge, where the gallery showed it cut at x≈-30 with the placeholder read as "place".
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { Icon } from "../src/icons";
import { FindPill } from "../src/ui/FindPill";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("editor-find-narrow.test.tsx", async () => {
  setDefaultTimeout(60_000);
  const src = path.resolve(import.meta.dir, "../src");
  const css = ["ui/findPill.css", "pages/editor/styles.css"]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");

  // What EditorFindBar renders with the replace row open, in English. The bar itself reads its
  // EditorFind through useSyncExternalStore, which static rendering can't run.
  const none = () => undefined;
  const bar = renderToStaticMarkup(
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
        icon={(role) => <Icon name={{ search: "search", previous: "chevronUp", next: "chevronDown", close: "close" }[role]} />}
        replace={{
          open: true,
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
    for (const width of [360, 300]) {
      test(`stays inside a ${width}px editor with the replace row open`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 200 } });
        await page.setContent(
          `<style>${css} body { margin: 0 }</style><div class="ed-frame" style="height: 200px">${bar}</div>`,
        );
        const box = await page.locator(".find-pill").boundingBox();
        await page.close();
        expect(box).not.toBeNull();
        expect(box!.x).toBeGreaterThanOrEqual(10);
        expect(box!.x + box!.width).toBeLessThanOrEqual(width - 10);
      });
    }
  });
});
