// A new chat's unsent draft in the real agent pane (cx-z5vd). The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with a stand-in host bridge (window.webkit.messageHandlers) and the
// in-page mock transport, as a chat that has not sent its first prompt has no acpmux session.
//
// - Such a chat hands its typed text to the host (`chat.unsentDraft`), which keeps it with the tab
//   across a relaunch (AgentUnsentDrafts); a relaunch hands it back as the handshake's `draft`.
// - The text it shows from that draft goes back to the host too, so it is kept again.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-unsent-draft.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-unsent-draft: skipping (run `bunx playwright install chromium`)");
    describe.skip("unsent draft", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
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

  /// A new chat whose host hands it `draft` (a relaunch's kept text), recording what the page
  /// hands back with `chat.unsentDraft`.
  type ChatOptions = {
    draft?: string;
    authState?: "signedOut" | "routeAuthNeeded";
    healthState?: "signedOut" | "unknown";
    started?: boolean;
  };
  async function newChat({
    draft,
    authState = "signedOut",
    healthState = authState === "signedOut" ? "signedOut" : "unknown",
    started = false,
  }: ChatOptions = {}): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(
      ({ draft, authState, healthState, started }) => {
        const unsent: string[] = [];
        const nativeCalls: { method: string; params: Record<string, unknown> }[] = [];
        Object.assign(window, {
          nativeCalls,
          cmuxAcpmuxMockNative: {
            "harness.health": {
              health:
                healthState === "signedOut"
                  ? { id: "claude", auth: "signedOut", login: "claude auth login" }
                  : { id: "claude", auth: "unknown" },
            },
          },
          cmuxAcpmuxMockSessionAuth: {
            state: authState,
            source: "authCheck",
            evidenceAt: Date.now(),
            harness: "claude",
            host: null,
            routeId: null,
            fromSessionId: null,
            login:
              authState === "signedOut"
                ? { kind: "terminal", command: "claude auth login" }
                : { kind: "route", routeId: "team-route" },
          },
          cmuxGalleryLog: [],
          unsentDrafts: unsent,
          webkit: {
            messageHandlers: {
              agentSession: {
                postMessage: async ({ method, params }: { method: string; params: Record<string, unknown> }) => {
                  nativeCalls.push({ method, params });
                  if (method === "chat.unsentDraft") unsent.push(String(params.text));
                  return { ok: true, value: null };
                },
              },
            },
          },
          cmuxAcpmuxActions: {
            ready: async () => ({
              protocolVersion: 1,
              transport: "mock",
              newSession: !started,
              ...(draft ? { draft } : {}),
            }),
          },
        });
      },
      { draft, authState, healthState, started },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// The last text the page handed the host, once it is `expected` (else what it is after 5 s).
  async function lastUnsent(page: Page, expected: string): Promise<string | undefined> {
    const read = () => page.evaluate(() => (window as unknown as { unsentDrafts: string[] }).unsentDrafts.at(-1));
    await page
      .waitForFunction(
        (expected) => (window as unknown as { unsentDrafts: string[] }).unsentDrafts.at(-1) === expected,
        expected,
        { timeout: 5_000 },
      )
      .catch(() => {});
    return read();
  }

  async function expectBlockedDraft(page: Page, draft: string) {
    const prompt = page.locator(".acpmux-composer-prompt .ProseMirror");
    await prompt.click();
    await page.keyboard.type(draft);
    expect(await page.locator(".acpmux-send").isDisabled()).toBe(true);
    await page.keyboard.press("Enter");
    expect((await prompt.innerText()).trim()).toBe(draft);
    expect(await lastUnsent(page, draft)).toBe(draft);
    const daemon = await page.evaluate(
      () => (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog,
    );
    expect(daemon.some(({ method }) => method === "acpmux session/new" || method === "acpmux session/prompt")).toBe(
      false,
    );
  }

  describe("unsent draft", () => {
    test("a new chat hands its typed text to the host", async () => {
      const page = await newChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("compare the two retry policies");
      expect(await lastUnsent(page, "compare the two retry policies")).toBe("compare the two retry policies");
      await page.close();
    });

    test("a signed-out fresh chat shows Log In before send and keeps its draft", async () => {
      const page = await newChat();
      const prompt = page.locator(".acpmux-composer-prompt .ProseMirror");
      const notice = page.locator('[data-harness-notice="signedOut"]');
      await notice.waitFor();
      expect(await notice.count()).toBe(1);
      expect(await page.locator(".acpmux-composer-trust-note").count()).toBe(0);
      expect(await notice.innerText()).toContain("Log In");
      await expectBlockedDraft(page, "set up the retry policy");
      await page.locator('[data-harness-notice="signedOut"] [data-notice-action="login"]').click();
      expect((await prompt.innerText()).trim()).toBe("set up the retry policy");
      expect(await lastUnsent(page, "set up the retry policy")).toBe("set up the retry policy");
      const calls = await page.evaluate(
        () => (window as unknown as { nativeCalls: { method: string; params: Record<string, unknown> }[] }).nativeCalls,
      );
      expect(calls.filter(({ method }) => method === "tab.open")).toEqual([
        { method: "tab.open", params: { kind: "terminal", text: "claude auth login", run: true } },
      ]);
      const daemon = await page.evaluate(
        () => (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog,
      );
      expect(daemon.some(({ method }) => method === "acpmux _acpmux/session/auth")).toBe(true);
      expect(daemon.some(({ method }) => method === "acpmux session/new" || method === "acpmux session/prompt")).toBe(
        false,
      );
      await page.close();
    });

    test("a fresh signed-out chat shows the composer line after Not Now", async () => {
      const page = await newChat();
      const card = page.locator('[data-harness-notice="signedOut"]');
      await card.waitFor();
      await card.locator('[data-notice-action="dismiss"]').click();
      const line = page.locator(".acpmux-composer-trust-note");
      await line.waitFor();
      expect(await card.count()).toBe(0);
      expect(await line.count()).toBe(1);
      await expectBlockedDraft(page, "blocked draft");
      await page.close();
    });

    test("a fresh route-auth target keeps one composer recovery line", async () => {
      const page = await newChat({ authState: "routeAuthNeeded" });
      expect(await page.locator('[data-harness-notice="signedOut"]').count()).toBe(0);
      const line = page.locator(".acpmux-composer-trust-note");
      await line.waitFor();
      expect(await line.count()).toBe(1);
      expect(await line.innerText()).toContain("Log In");
      await expectBlockedDraft(page, "route draft");
      await page.close();
    });

    test("a fresh route-auth target with signed-out health still shows one card", async () => {
      const page = await newChat({ authState: "routeAuthNeeded", healthState: "signedOut" });
      await page.locator('[data-harness-notice="signedOut"]').waitFor();
      expect(await page.locator('[data-harness-notice="signedOut"]').count()).toBe(1);
      expect(await page.locator(".acpmux-composer-trust-note").count()).toBe(0);
      await expectBlockedDraft(page, "conflicting health draft");
      await page.locator('[data-notice-action="dismiss"]').click();
      const line = page.locator(".acpmux-composer-trust-note");
      await line.waitFor();
      expect(await line.count()).toBe(1);
      expect(await line.innerText()).toContain("team-route");
      expect(await page.locator(".acpmux-send").isDisabled()).toBe(true);
      expect(await page.locator('[data-harness-notice="signedOut"]').count()).toBe(0);
      await page.locator(".acpmux-composer-prompt .ProseMirror").click();
      await page.keyboard.press("Enter");
      expect((await page.locator(".acpmux-composer-prompt .ProseMirror").innerText()).trim()).toBe(
        "conflicting health draft",
      );
      const sent = await page.evaluate(() =>
        (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.some(
          ({ method }) => method === "acpmux session/new" || method === "acpmux session/prompt",
        ),
      );
      expect(sent).toBe(false);
      await page.close();
    });

    test("a started signed-out chat keeps only the existing card", async () => {
      const page = await newChat({ started: true });
      await page.locator('[data-harness-notice="signedOut"]').waitFor();
      expect(await page.locator('[data-harness-notice="signedOut"]').count()).toBe(1);
      expect(await page.locator(".acpmux-composer-trust-note").count()).toBe(0);
      await page.close();
    });

    test("a relaunched new chat shows its kept draft and keeps what is typed after it", async () => {
      const page = await newChat({ draft: "compare the two" });
      const prompt = page.locator(".acpmux-composer-prompt .ProseMirror");
      await page.getByText("compare the two").waitFor();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("End");
      await page.keyboard.type(" retry policies");
      expect((await prompt.innerText()).trim()).toBe("compare the two retry policies");
      expect(await lastUnsent(page, "compare the two retry policies")).toBe("compare the two retry policies");
      await page.close();
    });
  });
});
