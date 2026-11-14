// Leo, 2026-11-08 (a screenshot could not reach a chat from another app): "holy fuck. those NEED to
// be written down and FIXED and IMPROVED". The app's `attachExternal` command (Send to cmux Chat, an
// image opened with cmux) makes the page take the files the host holds (`chat.attach.external`) and
// put them into the composer as an unsent draft, as a drop's are: the chip says which app it came
// from (`chat.attach.source {kind: "external"}`), nothing is sent, and the composer has the keyboard.
// `composerState` (what `chat.composer.get` reads) answers the chip.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-attach-external.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-attach-external: skipping (run `bunx playwright install chromium`)");
    describe.skip("files from another app", () => test("chromium", () => {}));
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

  test("attachExternal puts the host's image into the composer, unsent, with its source", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
      const asked: { method: string; params: unknown }[] = [];
      let held = [{ name: "Screenshot 2026-11-14.png", type: "image/png", data: png }];
      Object.assign(window, {
        asked,
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }),
          // The host answers its files once.
          "chat.attach.external": async (params: unknown) => {
            asked.push({ method: "chat.attach.external", params });
            const files = held;
            held = [];
            return { files };
          },
          "chat.attach.source": async (params: unknown) => {
            asked.push({ method: "chat.attach.source", params });
            return { sources: [{ name: "Preview", bundleId: "com.apple.Preview" }] };
          },
          "chat.attach.dropped": async () => ({ items: [] }),
        },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    expect(await page.evaluate(() => window.cmuxAcpmuxBridge?.composerState?.())).toEqual({
      text: "",
      attachments: [],
    });

    await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("attachExternal"));
    await page.waitForFunction(() => window.cmuxAcpmuxBridge?.composerState?.()?.attachments[0]?.source === "Preview");
    const state = await page.evaluate(() => window.cmuxAcpmuxBridge?.composerState?.());
    expect(state?.attachments.map(({ name, mimeType, source }) => ({ name, mimeType, source }))).toEqual([
      { name: "Screenshot 2026-11-14.png", mimeType: "image/png", source: "Preview" },
    ]);
    expect(state?.attachments[0]!.bytes).toBeGreaterThan(0);
    // It is a draft: the prompt keeps it, and the composer has the keyboard.
    expect(state?.text).toBe("");
    expect(await page.evaluate(() => document.activeElement?.closest(".acpmux-composer-prompt") !== null)).toBe(true);
    // The source was asked as the external gesture's.
    const asked = await page.evaluate(
      () => (window as unknown as { asked: { method: string; params: { kind?: string } }[] }).asked,
    );
    expect(asked.map((entry) => entry.method)).toEqual(["chat.attach.external", "chat.attach.source"]);
    expect(asked[1]!.params.kind).toBe("external");

    // A second command with nothing held adds nothing.
    await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("attachExternal"));
    await page.waitForFunction(() => ((window as unknown as { asked: unknown[] }).asked.length ?? 0) >= 3);
    expect((await page.evaluate(() => window.cmuxAcpmuxBridge?.composerState?.()))?.attachments.length).toBe(1);
    await page.close();
  });
});
