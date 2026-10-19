// The agent question card answers from the keyboard and hands the answer to the host (Leo
// 2026-10-19, the Claude app's AskUserQuestion card, "this is decent ui cmux next should have it").
// A pending ask shows a "Needs your input" pill over a card with the question as its header; the
// card has the keyboard when it arrives on an empty composer, so arrows move between the options,
// ⌘↩ submits, Esc skips and a number key picks Other to type an answer. What the card sends is the
// host's `chat.permission` call, which the pane relay sends as `_acpmux/permission_respond` and
// acpmux hands the agent (cmux-tui/crates/acpmux/tests/hub_integration/questions.rs).
//
// The page is the agent pane preview (vite.config.acpmux-preview.mjs) on the shared question
// fixture `pending-single` (Packages/Shared/CmuxAgentQuestion), a Claude Code AskUserQuestion.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-question-card.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-question-card: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent question card", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-preview.mjs"),
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

  type Call = { method: string; params: Record<string, unknown> };
  const prompt = "Which auth method should the API use?";

  /// The pending Claude question, recording each `chat.permission` the page hands the host.
  async function pendingQuestion(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?fixture=question-pending-single`);
    await page.locator(".acpmux-question").waitFor();
    await page.evaluate(() => {
      const calls: Call[] = [];
      const handler = window.webkit!.messageHandlers!.agentSession!;
      const post = handler.postMessage.bind(handler);
      handler.postMessage = (message: unknown) => {
        const { method, params } = message as Call;
        if (method === "chat.permission") calls.push({ method, params });
        return post(message);
      };
      Object.assign(window, { permissionCalls: calls });
    });
    return page;
  }

  /// The `chat.permission` calls so far, once at least `count` arrived.
  async function permissionCalls(page: Page, count: number): Promise<Call[]> {
    const read = () => page.evaluate(() => (window as unknown as { permissionCalls: Call[] }).permissionCalls);
    for (let i = 0; i < 100 && (await read()).length < count; i++) await page.waitForTimeout(50);
    return read();
  }

  const highlighted = (page: Page) =>
    page.locator(".acpmux-question-row[data-highlighted] .acpmux-question-label").innerText();

  describe("agent question card", () => {
    test("shows a Needs your input pill over a card headed by the question", async () => {
      const page = await pendingQuestion();
      const pill = page.locator(".acpmux-question-status");
      expect((await pill.innerText()).trim()).toBe("Needs your input");
      expect((await page.locator(".acpmux-question-prompt").innerText()).trim()).toBe(prompt);
      const labels = await page.locator(".acpmux-question-row .acpmux-question-label").allInnerTexts();
      expect(labels).toEqual(["OAuth 2.0", "API keys", "Passkeys", "Other"]);
      expect(await page.locator(".acpmux-question-row[role=radio]").count()).toBe(4);
      expect((await page.locator(".acpmux-question-submit").innerText()).replace(/\s+/g, "")).toBe("Submit⌘↩");

      // The pill's chevron folds the card away and back; the ask stays pending and keeps the pick.
      await page.keyboard.press("ArrowDown");
      await pill.click();
      expect(await pill.getAttribute("aria-expanded")).toBe("false");
      expect(await page.locator(".acpmux-question").isVisible()).toBe(false);
      await pill.click();
      await page.locator(".acpmux-question").waitFor();
      expect(await highlighted(page)).toBe("API keys");
      expect(await permissionCalls(page, 0)).toEqual([]);
      await page.close();
    });

    test("arrows pick an option and ⌘↩ sends it to the agent", async () => {
      const page = await pendingQuestion();
      // No click first: the card has the keyboard on an empty composer.
      expect(await highlighted(page)).toBe("OAuth 2.0");
      await page.keyboard.press("ArrowDown");
      expect(await highlighted(page)).toBe("API keys");
      await page.keyboard.press("Meta+Enter");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: { permissionId: "perm_toolu_single", optionId: "allow_once", answers: { [prompt]: "API keys" } },
        },
      ]);
      await page.close();
    });

    test("Esc skips the question: the agent gets its decline", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("Escape");
      expect(await permissionCalls(page, 1)).toEqual([
        { method: "chat.permission", params: { permissionId: "perm_toolu_single", optionId: "reject_once" } },
      ]);
      await page.close();
    });

    test("Other takes a typed answer, which ⌘↩ sends", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("4");
      const field = page.locator(".acpmux-question-other input");
      await field.waitFor();
      await page.keyboard.type("Signed cookies");
      // Esc in the field only leaves it; nothing is sent.
      await page.keyboard.press("Escape");
      expect(await permissionCalls(page, 0)).toEqual([]);
      await page.keyboard.press("Meta+Enter");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: {
            permissionId: "perm_toolu_single",
            optionId: "allow_once",
            answers: { [prompt]: "Signed cookies" },
          },
        },
      ]);
      await page.close();
    });
  });
});
