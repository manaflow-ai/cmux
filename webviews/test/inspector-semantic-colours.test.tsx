// The wire inspector's errors are status, never diff deletion colours.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser, type Page } from "playwright";
import { Inspector } from "../src/agent-session/acpmux/Inspector";
import { AcpWireLog } from "../src/agent-session/acpmux/wire";
import { chat } from "../src/gallery/fixtures/acpmux";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("inspector-semantic-colours.test.tsx", async () => {
  const css = [
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "ui/ui.css",
    "agent-session/acpmux/Inspector.css",
  ]
    .map((file) => readFileSync(path.resolve(import.meta.dir, "../src", file), "utf8"))
    .join("\n");
  const wire = new AcpWireLog(
    () => 0,
    () => 0,
  );
  wire.sent('{"id":1,"method":"session/load"}', "session/load", 1);
  wire.received('{"id":1,"error":{"message":"Session unavailable"}}');
  wire.received("Invalid fixture response");
  const inspector = renderToStaticMarkup(
    <Inspector snapshot={chat([])} sessionEvents={() => []} onClose={() => undefined} wire={wire} />,
  );
  const computed = (page: Page, selector: string, property: "color" | "backgroundColor") =>
    page
      .locator(selector)
      .first()
      .evaluate((element, property) => getComputedStyle(element)[property], property);
  const tokenColour = (page: Page, token: string) =>
    page.evaluate((token) => {
      const probe = document.createElement("span");
      probe.style.color = `var(${token})`;
      document.body.append(probe);
      const result = getComputedStyle(probe).color;
      probe.remove();
      return result;
    }, token);
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const scheme of ["light", "dark"] as const) {
    describe(scheme, () => {
      const setup = async () => {
        const page = await browser.newPage({ colorScheme: scheme });
        await page.setContent(`<style>${css}
          :root { color-scheme: ${scheme}; --cmux-text: CanvasText; --agent-page-bg: Canvas; }
        </style>${inspector}`);
        return page;
      };
      test("last error and error kinds follow the status palette independently of diff colours", async () => {
        const page = await setup();
        try {
          for (const deletion of ["GrayText", "rebeccapurple", "transparent"]) {
            await page.evaluate((value) => document.documentElement.style.setProperty("--acpmux-del", value), deletion);
            const expected = await tokenColour(page, "--agent-status-failure");
            for (const selector of [
              ".acpmux-inspector-wide dd",
              ".acpmux-inspector-error .acpmux-inspector-kind",
              ".acpmux-inspector-invalid .acpmux-inspector-kind",
            ])
              expect(await computed(page, selector, "color")).toBe(expected);
          }
          // A live theme change updates errors through the same semantic token.
          await page.evaluate(() => document.documentElement.style.setProperty("--agent-ansi-9", "rebeccapurple"));
          expect(await computed(page, ".acpmux-inspector-wide dd", "color")).toBe(
            await tokenColour(page, "--agent-status-failure"),
          );
        } finally {
          await page.close();
        }
      });
      test("tool and row hover use the shared control token before and after theme delivery", async () => {
        const page = await setup();
        try {
          for (const override of [undefined, "rebeccapurple"]) {
            if (override)
              await page.evaluate(
                (value) => document.documentElement.style.setProperty("--agent-control-hover", value),
                override,
              );
            for (const selector of [".acpmux-inspector-tools button", ".acpmux-inspector-row > button"]) {
              await page.locator(selector).first().hover();
              expect(await computed(page, selector, "backgroundColor")).toBe(
                await tokenColour(page, "--agent-control-hover"),
              );
            }
          }
        } finally {
          await page.close();
        }
      });
      test("destructive menus use host danger, agent danger, then readable unthemed foreground", async () => {
        const page = await browser.newPage({ colorScheme: scheme });
        try {
          const ui = readFileSync(path.resolve(import.meta.dir, "../src/ui/ui.css"), "utf8");
          await page.setContent(`<style>${ui} :root { color-scheme: ${scheme}; }</style>
            <div class="ui-popup"><button class="ui-menu-item ui-menu-item-destructive">Delete</button><span data-reference>Reference</span></div>`);
          const check = async (value: string) => {
            await page
              .locator("[data-reference]")
              .evaluate((element, value) => ((element as HTMLElement).style.color = value), value);
            expect(await computed(page, ".ui-menu-item-destructive", "color")).toBe(
              await computed(page, "[data-reference]", "color"),
            );
          };
          await check("CanvasText");
          await page.evaluate(() => document.documentElement.style.setProperty("--agent-danger", "rebeccapurple"));
          await check("var(--agent-danger)");
          await page.evaluate(() => document.documentElement.style.setProperty("--cmux-app-danger", "MarkText"));
          await check("var(--cmux-app-danger)");
        } finally {
          await page.close();
        }
      });
    });
  }
});
