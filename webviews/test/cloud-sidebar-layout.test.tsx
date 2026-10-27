// Real layout checks: a DOM shim cannot detect flex wrapping or intrinsic grid overflow.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { chromium, webkit, type Browser } from "playwright";
import { renderToStaticMarkup } from "react-dom/server";
import { AccountPanel } from "../src/pages/cloud/AccountPanel";
import { MachineList } from "../src/pages/cloud/MachineList";
import { MockCloudProvider } from "../src/pages/cloud/mockProvider";
import { CloudStore } from "../src/pages/cloud/store";
import { formatString, type Strings } from "../src/pages/shared/i18n";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cloud-sidebar-layout.test.tsx", async () => {
  const css = readFileSync(new URL("../src/pages/cloud/styles.css", import.meta.url), "utf8");
  const catalog = JSON.parse(
    readFileSync(new URL("../src/pages/cloud/Localizable.xcstrings", import.meta.url), "utf8"),
  );
  const store = new CloudStore(new MockCloudProvider());
  const browsers: Browser[] = [];
  beforeAll(async () => {
    await store.start();
    for (const engine of [chromium, webkit]) browsers.push(await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    store.stop();
    await Promise.all(browsers.map((browser) => browser.close()));
  });

  function content(language: string, layout: "rows" | "cards", storefront = false) {
    const t = (key: string): string =>
      catalog.strings[key]?.localizations[language]?.stringUnit.value ??
      catalog.strings[key]?.localizations.en?.stringUnit.value ??
      key;
    const strings: Strings = { language, t, format: (key, ...args) => formatString(t(key), args) };
    const state = store.getSnapshot();
    const account = <AccountPanel store={store} state={state} strings={strings} />;
    return renderToStaticMarkup(
      <div className="cloud-page">
        {storefront ? (
          <div className="cloud-store-account">{account}</div>
        ) : (
          <div className={`cloud-body layout-${layout}`}>
            <section className="cloud-machines">
              <MachineList
                rows={state.rows}
                layout={layout}
                strings={strings}
                onSelect={() => {}}
                onOpen={() => {}}
                onPause={() => {}}
                onResume={() => {}}
              />
            </section>
            <div className="cloud-message cloud-detail-placeholder">{t("detail.selectMachine")}</div>
            {account}
          </div>
        )}
      </div>,
    );
  }

  for (const language of ["en", "de", "ar"]) {
    for (const layout of ["rows", "cards"] as const) {
      test(`${language} ${layout}: account values fit and all columns stay reachable`, async () => {
        for (const browser of browsers) {
          const page = await browser.newPage();
          try {
            for (const width of [360, 560, 860, 880, 960, 961, 1000, 1200, 1400]) {
              await page.setViewportSize({ width, height: 360 });
              await page.setContent(`<html dir="${language === "ar" ? "rtl" : "ltr"}"><head><style>
                :root { --font-ui: sans-serif; --page-edge: 18px; }
                ${css}</style></head><body>${content(language, layout)}</body></html>`);
              const overflow = await page
                .locator(".cloud-body, .cloud-account, .cloud-meter")
                .evaluateAll((nodes) =>
                  nodes.filter((node) => node.scrollWidth > node.clientWidth + 1).map((node) => node.className),
                );
              expect(overflow, `${browser.browserType().name()} ${language} ${layout} ${width}px`).toEqual([]);
              const account = await page.locator(".cloud-account").boundingBox();
              expect(account!.x).toBeGreaterThanOrEqual(0);
              expect(account!.x + account!.width).toBeLessThanOrEqual(width + 1);
              if (width <= 960) {
                const detail = await page.locator(".cloud-detail-placeholder").boundingBox();
                expect(account!.y).toBeGreaterThanOrEqual(detail!.y + detail!.height);
              }
            }
          } finally {
            await page.close();
          }
        }
      });
    }
    test(`${language}: storefront has no rail separator`, async () => {
      for (const browser of browsers) {
        const page = await browser.newPage();
        try {
          for (const width of [560, 1200]) {
            await page.setViewportSize({ width, height: 680 });
            await page.setContent(`<html dir="${language === "ar" ? "rtl" : "ltr"}"><head><style>
              :root { --font-ui: sans-serif; --page-edge: 18px; }
              ${css}</style></head><body>${content(language, "rows", true)}</body></html>`);
            const borders = await page.locator(".cloud-account").evaluate((node) => {
              const style = getComputedStyle(node);
              return [style.borderInlineStartWidth, style.borderTopWidth];
            });
            expect(borders, `${browser.browserType().name()} ${language} ${width}px`).toEqual(["0px", "0px"]);
          }
        } finally {
          await page.close();
        }
      }
    });
  }
});
