// cmux-web-test-timeout: 600
// A change in flight in a Settings card disables its rows' controls through a disabled fieldset
// (cardWindow.ts cardBusy for the Customization Library and Shared Links, ProviderAccounts'
// BusyControls for a harness's accounts), so no row renders. Chromium's accessibility tree does not
// refresh a control's `focusable` and `disabled` when only its fieldset's `disabled` changes: with
// the tree already live (a screen reader running), every waiting Switch and button stayed
// focusable and enabled to it, while the page disabled them. Each waiting control now also says
// aria-disabled="true" while it waits, which refreshes it, so the tree matches what it showed when
// each control carried `disabled` itself.
//
// A production build of test/browser/settings-busy-ax.html (the real page over the mock host). The
// test enables the accessibility domain and reads the whole tree before the press, holds the card's
// change, and reads every waiting control's node: disabled and not focusable while it waits, then
// focusable and enabled (unless disabled for its own reason, such as the first entry's Move Up) once
// it answers. Chromium only: WebKit exposes no accessibility tree to the test (Playwright's
// ariaSnapshot reads the DOM, not the browser's tree).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/settings-busy-ax-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type CDPSession, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

type AxState = { focusable: boolean; disabled: boolean };

await requireBrowserLane("settings-busy-ax-browser.test.ts", async () => {
  /** Every waiting control's node in the browser's accessibility tree, in DOM order. */
  async function axStates(cdp: CDPSession, selector: string): Promise<AxState[]> {
    const { root } = await cdp.send("DOM.getDocument", { depth: 0 });
    const { nodeIds } = await cdp.send("DOM.querySelectorAll", { nodeId: root.nodeId, selector });
    const states: AxState[] = [];
    for (const nodeId of nodeIds) {
      const { nodes } = await cdp.send("Accessibility.getPartialAXTree", { nodeId, fetchRelatives: false });
      const property = (name: string) => nodes[0]?.properties?.find((one) => one.name === name)?.value.value === true;
      states.push({ focusable: property("focusable"), disabled: property("disabled") });
    }
    return states;
  }

  /** The waiting controls' own `disabled` (a reason of their own, outside the change) in DOM order. */
  const ownDisabled = (page: Page, selector: string) =>
    page.evaluate(
      (selector) => [...document.querySelectorAll<HTMLButtonElement>(selector)].map((one) => one.disabled),
      selector,
    );

  /** Two painted frames, so the browser has run its accessibility update for the last commit. */
  const painted = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 0))),
        ),
    );

  setDefaultTimeout(240_000);
  const run = await probeEngineOrSkip("settings-busy-ax-browser chromium", "chromium", chromium);
  let served: BenchPage;
  let browser: Browser | undefined;
  beforeAll(async () => {
    // `bun test` runs with NODE_ENV=test, and Vite's JSX transform follows it: the page is built as
    // a user runs it, with production React.
    const nodeEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/settings-busy-ax.html");
    } finally {
      process.env.NODE_ENV = nodeEnv;
    }
    if (run) browser = await chromium.launch({ headless: true });
  }, 300_000);
  afterAll(async () => {
    await browser?.close();
    await served?.close();
  });

  const cards = [
    {
      card: "library",
      name: "Customization Library",
      // Every control of a row waits: Move Up, Move Down, Remove and the switch.
      waits: '[data-card="customizeLibrary"] [data-library-entry] button',
      rows: '[data-card="customizeLibrary"] [data-library-entry]',
      press: '[role="switch"]',
    },
    {
      card: "shares",
      name: "Shared Links",
      waits: '[data-card="sharedLinks"] [data-shared-link] [data-shared-link-action="revoke"]',
      rows: '[data-card="sharedLinks"] [data-shared-link]',
      press: '[data-shared-link-action="revoke"]',
    },
    {
      card: "accounts",
      name: "a harness's accounts",
      // The gesture buttons and the routing switches.
      waits:
        '[data-card="harnesses"] [data-harness="codex"] [data-account] [data-account-action], [data-card="harnesses"] [data-harness="codex"] [data-account] [role="switch"]',
      rows: '[data-card="harnesses"] [data-harness="codex"] [data-account]',
      press: '[role="switch"]',
    },
  ] as const;

  for (const { card, name, waits, rows, press } of run ? cards : []) {
    test(`chromium: ${name}: with the accessibility tree live, a change in flight leaves every waiting control disabled and not focusable, and gives them back on answer`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1200, height: 900 } });
      try {
        await gotoBenchPage(page, { ...served, url: `${served.url}#card=${card}&n=60` });
        await requireProductionReact(page, { dev: served.dev });
        // The fourth row's control (the second account's routing switch).
        const target = page
          .locator(rows)
          .nth(card === "accounts" ? 1 : 3)
          .locator(press);
        await page.waitForFunction(() => (window as { axReady?: boolean }).axReady === true);
        await target.scrollIntoViewIfNeeded();
        await painted(page);
        // The tree is live before the change, as with a screen reader running.
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Accessibility.enable");
        await cdp.send("Accessibility.getFullAXTree");
        const own = await ownDisabled(page, waits);
        expect(own.length).toBeGreaterThan(card === "shares" ? 5 : 6);
        const before = await axStates(cdp, waits);
        expect(before.map((one) => one.focusable)).toEqual(own.map((disabled) => !disabled));

        await page.evaluate(() => window.axHold());
        await target.click();
        await target.and(page.locator(":disabled")).waitFor();
        await painted(page);
        expect(await page.evaluate(() => window.axCalls())).toBe(1);
        const busy = await axStates(cdp, waits);
        expect(busy.length).toBe(own.length);
        expect(busy.filter((one) => one.focusable || !one.disabled)).toEqual([]);
        if (card !== "accounts") {
          // A scroll while it waits mounts rows the change never saw: they wait too, and come back.
          const scrolled = await page.evaluate(() => {
            const scroller = document.querySelector<HTMLElement>("main.content")!;
            scroller.scrollBy(0, 2_500);
            return scroller.scrollTop;
          });
          expect(scrolled).toBeGreaterThan(0);
          await painted(page);
          await painted(page);
          const moved = await axStates(cdp, waits);
          expect(moved.length).toBeGreaterThan(5);
          expect(moved.filter((one) => one.focusable || !one.disabled)).toEqual([]);
        }

        await page.evaluate(() => window.axAnswer());
        await page.waitForFunction((waits) => !document.querySelector(waits)!.closest("fieldset:disabled"), waits);
        await painted(page);
        const after = await axStates(cdp, waits);
        const ownAfter = await ownDisabled(page, waits);
        expect(after).toEqual(ownAfter.map((disabled) => ({ focusable: !disabled, disabled })));
        await cdp.detach();
      } finally {
        await page.close();
      }
    });
  }

  // An account's Rename comes back when its rename is cancelled; cancelled while a change waits, it
  // mounts with no new list, so the card's own pass never saw it.
  if (run) {
    test(`chromium: a harness's accounts: with the accessibility tree live, a Rename brought back by a cancel while a change waits is disabled and not focusable, and comes back on answer`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1200, height: 900 } });
      try {
        await gotoBenchPage(page, { ...served, url: `${served.url}#card=accounts&n=3` });
        await requireProductionReact(page, { dev: served.dev });
        await page.waitForFunction(() => (window as { axReady?: boolean }).axReady === true);
        const rows = page.locator('[data-card="harnesses"] [data-harness="codex"] [data-account]');
        const rename =
          '[data-card="harnesses"] [data-harness="codex"] [data-account="codex-2"] [data-account-action="rename"]';
        await page.locator(rename).click();
        const form = rows.nth(1).locator("[data-account-rename]");
        await form.waitFor();
        const target = rows.nth(2).locator('[role="switch"]');
        await target.scrollIntoViewIfNeeded();
        await painted(page);
        // The tree is live before the change, as with a screen reader running.
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Accessibility.enable");
        await cdp.send("Accessibility.getFullAXTree");

        await page.evaluate(() => window.axHold());
        await target.click();
        await target.and(page.locator(":disabled")).waitFor();
        await form.locator('button[type="button"]').click();
        await page.locator(rename).waitFor();
        await painted(page);
        expect(await page.evaluate(() => window.axCalls())).toBe(1);
        expect(await page.locator(rename).getAttribute("aria-disabled")).toBe("true");
        expect(await axStates(cdp, rename)).toEqual([{ focusable: false, disabled: true }]);

        await page.evaluate(() => window.axAnswer());
        await page.waitForFunction((rename) => !document.querySelector(rename)!.closest("fieldset:disabled"), rename);
        await painted(page);
        expect(await page.locator(rename).getAttribute("aria-disabled")).toBeNull();
        expect(await axStates(cdp, rename)).toEqual([{ focusable: true, disabled: false }]);
        await cdp.detach();
      } finally {
        await page.close();
      }
    });
  }
});
