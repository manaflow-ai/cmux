// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture text, not shipped UI.
// Leo-Ask-Trace: ask-e1768ff161
// Exercise actual pointer entry in the mounted transcript: focus-only chip tests cannot catch
// a mouse hover that never opens its timestamp or link preview.
import { expect, test } from "bun:test";
import { chromium, webkit, type BrowserType } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-hover-previews.test.ts", async () => {
  // Each engine is probed first: one that cannot launch here (the fleet pool has no WebKit host
  // libraries) skips its cases; GitHub Actions still fails the file (probeEngineOrSkip).
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][])
    if (await probeEngineOrSkip("transcript-hover-previews.test.ts", engine[0], engine[1])) engines.push(engine);
  for (const [name, engine] of engines) {
    test(`${name}: message timestamps and link previews open on pointer hover`, async () => {
      const browser = await engine.launch({ headless: true });
      const pane = await papercutPane(() => browser, {
        turns: 0,
        running: false,
        extra: [
          ["mux", "user_message", { text: "Check the reference" }],
          ["mux", "turn_started", {}],
          [
            "in",
            "agent_message_chunk",
            {
              method: "session/update",
              params: {
                sessionId: "agent-1",
                update: {
                  sessionUpdate: "agent_message_chunk",
                  content: {
                    type: "text",
                    text: "Read [the reference](https://example.com/reference).",
                  },
                },
              },
            },
          ],
          ["mux", "turn_result", { status: "completed" }],
        ],
        ready: 'a[href="https://example.com/reference"]',
      });
      try {
        const page = await pane.open({ width: 1100, height: 900 });
        await page.mouse.move(2, 2);
        await page.locator(".cv-user").first().hover();
        const timestamp = page.locator("time.cv-user__time").first();
        await timestamp.hover();
        await page.locator(".ui-title-tooltip:not([hidden])").waitFor({ timeout: 3000 });
        expect(await page.locator(".ui-title-tooltip:not([hidden])").textContent()).toContain("2026");
        if (process.env.FAST_CHECKS_OUT)
          await page.screenshot({ path: `${process.env.FAST_CHECKS_OUT}/${name}-timestamp.png` });
        await page.mouse.move(2, 2);
        await page.locator('a[href="https://example.com/reference"]').hover();
        await page.locator(".cv-link-preview").waitFor({ timeout: 3000 });
        expect(await page.locator(".cv-link-preview").textContent()).toContain("example.com");
        if (process.env.FAST_CHECKS_OUT)
          await page.screenshot({ path: `${process.env.FAST_CHECKS_OUT}/${name}-link.png` });
        await page.mouse.move(2, 2);
        await page.locator(".cv-link-preview").waitFor({ state: "hidden", timeout: 3000 });
      } finally {
        await pane.close();
        await browser.close();
      }
    }, 100_000);
  }
});
