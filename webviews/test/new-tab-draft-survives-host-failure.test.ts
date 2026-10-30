// cmux-web-test-timeout: 300
// Leo, 2026-10-28: "when I updated, it removed my draft in one of the composer things", and
// (ask-57e1c63246) "new updates overwrite the text portion of the draft and it becomes empty".
// Before the handshake the New Tab page shows and takes keys. A host that fails then swaps in the
// chat view's error card, which unmounts the page; the retry that answers mounts it again. That
// remount started empty: what was typed, and what was pasted, was gone. The page now hands its
// draft to App when the host failure takes it (`onLeaveDraft`), and takes it back when it comes
// back (`takeDraft`), on both templates (NewTabScreen.tsx and the Classic NewTabPage.tsx).
//
// The pane's dev entry as a New Tab page on the in-page mock transport, whose `ready` fails once
// when the test says so and answers after. Real Chromium; CI fails the file when it cannot launch
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-draft-survives-host-failure.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-draft-survives-host-failure.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-draft-survives-host-failure: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab draft through a host failure", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// A New Tab page whose first `ready` waits until `failHost` fails it; every later one answers.
  async function newTab(classic: boolean): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript((classic) => {
      const newTab = {
        kind: "agent",
        hotkeys: {},
        home: "/Users/you",
        projects: [],
        ...(classic ? { template: "classic" } : {}),
      };
      let asked = 0;
      let fail: (error: Error) => void = () => {};
      Object.assign(window, {
        __cmuxNewTabContext: newTab,
        failHost: () => fail(new Error("acpmux is not running")),
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: {
          ready: () =>
            asked++ === 0
              ? new Promise((_, reject) => (fail = reject))
              : Promise.resolve({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
        },
      });
    }, classic);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    return page;
  }

  // Fleet captures use the same real-browser interaction as the regression, with generated
  // text and image only. The optional directory is collected by the hosted artifact step.
  async function captureDraft(page: Page, classic: boolean, phase: string) {
    const directory = process.env.CMUX_DRAFT_CAPTURE_DIR;
    if (!directory) return;
    await mkdir(directory, { recursive: true });
    for (const colorScheme of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme });
      await page.screenshot({ path: path.join(directory, `${classic ? "classic" : "new-tab"}-${phase}-${colorScheme}.png`) });
    }
    await page.emulateMedia({ colorScheme: "light" });
  }

  /// A PNG pasted on `field`, as a copied screenshot is.
  async function pasteImage(page: Page, selector: string) {
    const data = await page.evaluateHandle(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 64;
      canvas.height = 64;
      canvas.getContext("2d")!.fillRect(0, 0, 64, 64);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const transfer = new DataTransfer();
      transfer.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      return transfer;
    });
    await page
      .locator(selector)
      .evaluate(
        (node, data) =>
          node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
        data,
      );
  }

  for (const [name, classic, field, chip] of [
    [
      "New Tab",
      false,
      ".nt-field",
      ".nt-box .acpmux-attachments .acpmux-attachment-image:not(.acpmux-attachment-pending)",
    ],
    [
      "Classic New Tab",
      true,
      "input.acpmux-newtab-field",
      ".acpmux-attachments .acpmux-attachment-image:not(.acpmux-attachment-pending)",
    ],
  ] as const) {
    test(`${name}: the typed text and a pasted image are still there after the host fails and the retry answers`, async () => {
      const page = await newTab(classic);
      await page.locator(field).waitFor();
      await page.locator(field).click();
      await page.keyboard.type("compare the two retry policies");
      await pasteImage(page, field);
      // Read (no longer pending): a staged attachment.
      await page.locator(chip).waitFor();

      await captureDraft(page, classic, "before-failure");

      // The host fails: the error card takes the page's place.
      await page.evaluate(() => (window as unknown as { failHost(): void }).failHost());
      await page.locator(field).waitFor({ state: "detached" });

      // The retry (the backoff's own, or Retry on the card) answers, and the page comes back.
      const retry = page.getByRole("button", { name: "Retry" });
      if (await retry.isVisible().catch(() => false)) await retry.click().catch(() => {});
      await page.locator(field).waitFor({ timeout: 30_000 });
      expect(await page.locator(field).inputValue()).toBe("compare the two retry policies");
      await page
        .locator(chip)
        .first()
        .waitFor({ timeout: 10_000 })
        .catch(() => {});
      expect(await page.locator(chip).count()).toBe(1);
      await captureDraft(page, classic, "after-retry");
      await page.close();
    });
  }
});
