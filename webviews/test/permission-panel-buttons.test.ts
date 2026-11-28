// An approval's answers stay in view (dogfood run 6). With the proposed diff drawn on the card
// (cx-d73v2), an edit's card grew past the permission panel's height cap, and the panel showed
// its top: the title and the diff, with Allow once, Allow for this chat and Deny scrolled out of
// sight below the composer. The answers are the point of the card: they stay in the panel's view
// however long the request is, and the request scrolls above them.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("permission-panel-buttons.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("permission-panel-buttons: skipping (run `bunx playwright install chromium`)");
    describe.skip("permission panel buttons", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/permission-panel.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const file = "/Users/you/src/uploader/src/upload.sh";
  const before = Array.from({ length: 30 }, (_, index) => `line ${index + 1}`).join("\n") + "\n";
  const after = before.replace("line 2\n", "# retried uploads\nline 2\n").replace("line 20\n", "line 20 retried\n");
  const state = {
    supported: true,
    ready: true,
    chatAllowance: false,
    loading: false,
    busy: false,
    groups: [
      {
        groupId: "group-1",
        sessionId: "session-1",
        turnId: "turn-2",
        revision: 1,
        state: "pending",
        decisions: ["allow_once", "allow_chat", "deny"],
        decision: null,
        items: [
          {
            permissionId: "permission-1",
            state: "pending",
            request: {
              toolCall: {
                title: "Edit upload.sh",
                kind: "edit",
                locations: [{ path: file }],
                content: [{ type: "diff", path: file, oldText: before, newText: after }],
              },
            },
          },
        ],
      },
    ],
  };

  test("a tall edit approval keeps Allow, Always and Deny in view", async () => {
    const page = await browser!.newPage({ viewport: { width: 880, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/permission-panel.html`);
    await page.waitForFunction(() => "__showPermissions" in window);
    await page.evaluate(
      (shown) => (window as unknown as { __showPermissions(state: unknown): void }).__showPermissions(shown),
      state,
    );
    await page.locator(".cv-edit-diff").waitFor();
    // The diff draws its rows after the element appears, later on a loaded runner with a cold dev
    // server (#20363 and #20379's react-apps-check read "tall" as false after a fixed 300 ms).
    // Wait for the request to outgrow the panel, then check what is in view.
    await page
      .waitForFunction(
        () =>
          [".acpmux-permission-panel", ".acpmux-ask"].some((selector) => {
            const node = document.querySelector(selector);
            return node !== null && node.scrollHeight > node.clientHeight + 1;
          }),
        null,
        { timeout: 10_000 },
      )
      .catch(() => undefined);
    const seen = await page.evaluate(() => {
      const panel = document.querySelector(".acpmux-permission-panel")!.getBoundingClientRect();
      return {
        // The request does not fit the panel: something has to scroll.
        tall: [".acpmux-permission-panel", ".acpmux-ask"].some((selector) => {
          const node = document.querySelector(selector)!;
          return node.scrollHeight > node.clientHeight + 1;
        }),
        // Each answer, wholly inside the panel's view.
        answers: [...document.querySelectorAll<HTMLElement>(".acpmux-ask-action")].map((button) => {
          const box = button.getBoundingClientRect();
          return { text: button.textContent, inView: box.top >= panel.top && box.bottom <= panel.bottom };
        }),
      };
    });
    expect(seen.tall).toBe(true);
    expect(seen.answers.map(({ inView }) => inView)).toEqual([true, true, true]);
    await page.close();
  });
});
