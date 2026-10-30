// Real pointer and keyboard input: a held button must differ from hover without moving its box.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser, type Locator } from "playwright";
import { FindPill } from "../src/ui/FindPill";
import { ImportCards } from "../src/ui/ImportCards";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("find-import-pressed.test.tsx", async () => {
  const css = ["pages/shared/desktop.css", "ui/findPill.css", "ui/importCards.css"]
    .map((file) => readFileSync(path.resolve(import.meta.dir, "../src", file), "utf8"))
    .join("\n");
  const noop = () => undefined;
  const fixture = (canStep = true) =>
    renderToStaticMarkup(
      <>
        <FindPill
          query="needle"
          onQueryChange={noop}
          status={canStep ? "1 of 3" : "No matches"}
          noMatches={!canStep}
          canStep={canStep}
          onNext={noop}
          onPrevious={noop}
          onClose={noop}
          matchCase
          onMatchCaseChange={noop}
          labels={{ placeholder: "Find", previous: "Previous", next: "Next", close: "Close", matchCase: "Match case" }}
          icon={(role) => <span>{role}</span>}
          replace={{
            open: true,
            value: "replacement",
            onChange: noop,
            onReplace: noop,
            onReplaceAll: noop,
            onToggle: noop,
            labels: { field: "Replace", replace: "Replace", replaceAll: "All", toggle: "Toggle Replace" },
          }}
        />
        <ImportCards
          list={{
            title: "Found on This Mac",
            cards: [
              {
                id: "browser.fixture",
                kind: "browser",
                title: "Browser",
                facts: "3 profiles",
                benefit: "Bring your bookmarks into cmux.",
                state: "ready",
                dismissed: false,
                primary: { action: "start", title: "Import" },
                secondary: [{ action: "dismiss", title: "Not Now" }],
              },
            ],
          }}
          onAction={noop}
        />
      </>,
    );
  const paint = (button: Locator) =>
    button.evaluate(async (element) => {
      await window.cmuxPaintFrame();
      const style = getComputedStyle(element);
      return { background: style.backgroundColor, color: style.color, opacity: style.opacity };
    });
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const theme of ["light", "dark"] as const) {
    describe(theme, () => {
      const setup = async (canStep = true) => {
        const page = await browser.newPage({ colorScheme: theme, reducedMotion: "reduce" });
        await page.setContent(`<style>${css}
          :root { --cmux-text: CanvasText; --cmux-accent: LinkText; --cmux-app-danger: MarkText; }
          body { margin: 24px; color: CanvasText; background: Canvas; }
        </style>${fixture(canStep)}`);
        await installPaintedFrames(page);
        return page;
      };
      for (const name of [
        "Previous",
        "Next",
        "Close",
        "Match case",
        "Toggle Replace",
        "Replace",
        "All",
        "Import",
        "Not Now",
      ]) {
        test(`${name} responds while held and restores its hover paint`, async () => {
          const page = await setup();
          try {
            const button = page.getByRole("button", { name, exact: true });
            const selectedPaint = await button.evaluate(() => {
              const probe = document.createElement("span");
              probe.style.backgroundColor = "color-mix(in srgb, var(--cmux-accent) 30%, transparent)";
              probe.style.color = "var(--cmux-accent)";
              document.body.append(probe);
              const style = getComputedStyle(probe);
              const result = { background: style.backgroundColor, color: style.color };
              probe.remove();
              return result;
            });
            await button.hover();
            const hovered = await paint(button);
            const box = await button.boundingBox();
            await page.mouse.down();
            const held = await paint(button);
            expect(held).not.toEqual(hovered);
            if (name === "Match case") {
              expect({ background: held.background, color: held.color }).toEqual(selectedPaint);
            }
            expect(await button.boundingBox()).toEqual(box);
            await page.mouse.up();
            expect(await paint(button)).toEqual(hovered);
          } finally {
            await page.close();
          }
        });
      }
      test("disabled Find actions keep their paint while held", async () => {
        const page = await setup(false);
        try {
          for (const name of ["Previous", "Next", "Replace", "All"]) {
            const button = page.getByRole("button", { name, exact: true });
            const box = await button.boundingBox();
            if (!box) throw new Error(`${name} has no box`);
            await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
            const before = await paint(button);
            await page.mouse.down();
            expect(await paint(button)).toEqual(before);
            await page.mouse.up();
          }
        } finally {
          await page.close();
        }
      });
      test("keyboard focus remains visible and Space gives press feedback", async () => {
        const page = await setup();
        try {
          const button = page.getByRole("button", { name: "Import", exact: true });
          await page.keyboard.press("Tab");
          await button.focus();
          expect(await button.evaluate((element) => element.matches(":focus-visible"))).toBe(true);
          expect(await button.evaluate((element) => getComputedStyle(element).outlineStyle)).toBe("solid");
          const before = await paint(button);
          await page.keyboard.down("Space");
          expect(await paint(button)).not.toEqual(before);
          await page.keyboard.up("Space");
          expect(await paint(button)).toEqual(before);
        } finally {
          await page.close();
        }
      });
      test("no-match status uses the host's danger token", async () => {
        const page = await setup(false);
        try {
          const count = page.locator(".find-pill__count");
          const expected = await page.evaluate(() => {
            const probe = document.createElement("span");
            probe.style.color = "var(--cmux-app-danger)";
            document.body.append(probe);
            const color = getComputedStyle(probe).color;
            probe.remove();
            return color;
          });
          expect(await count.evaluate((element) => getComputedStyle(element).color)).toBe(expected);
        } finally {
          await page.close();
        }
      });
    });
  }
});
