// The agent question card answers from the keyboard and hands the answer to the host (Leo
// 2026-10-19, the Claude app's AskUserQuestion card, "this is decent ui cmux next should have it").
// A pending ask shows a "Needs your input" pill over a card with the question as its header; the
// card has the keyboard when it arrives on an empty composer, so arrows move between the options,
// Enter and ⌘↩ submit, Esc skips the waiting ask, a
// click chooses an option and Submit sends it, and a number key picks Other to type an answer. What the card sends is the
// host's `chat.permission` call, which the pane relay sends as `_acpmux/permission_respond` and
// acpmux hands the agent (cmux-tui/crates/acpmux/tests/hub_integration/questions.rs).
//
// The page is the agent pane preview (vite.config.acpmux-preview.mjs) on the shared question
// fixture `pending-single` (Packages/Shared/CmuxAgentQuestion), a Claude Code AskUserQuestion.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
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
  async function pendingQuestion(fixture = "pending-single"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    page.setDefaultTimeout(5_000);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?fixture=question-${fixture}`);
    await page.locator(".acpmux-question").waitFor();
    await page.evaluate(() => {
      const calls: Call[] = [];
      const handler = window.webkit!.messageHandlers!.agentSession!;
      const post = handler.postMessage.bind(handler);
      handler.postMessage = (message: unknown) => {
        const { method, params } = message as Call;
        if (method === "chat.permission" || method === "chat.cancel") calls.push({ method, params });
        return post(message);
      };
      Object.assign(window, { permissionCalls: calls });
    });
    return page;
  }

  /// The `chat.permission` calls so far, once at least `count` arrived.
  async function permissionCalls(page: Page, count: number): Promise<Call[]> {
    await page
      .waitForFunction(
        (count) => (window as unknown as { permissionCalls: Call[] }).permissionCalls.length >= count,
        count,
        { timeout: 5_000 },
      )
      .catch(() => {});
    return page.evaluate(() => (window as unknown as { permissionCalls: Call[] }).permissionCalls);
  }

  const highlighted = (page: Page) =>
    page.locator(".acpmux-question-row[data-highlighted] .acpmux-question-label").innerText();

  /// A chat with no ask yet, whose composer has the keyboard (and `draft` typed, when given); the
  /// pending Claude question then arrives, as it does mid-chat.
  async function questionArrivesMidChat(draft = ""): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    page.setDefaultTimeout(5_000);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?fixture=worked-turn`);
    const composer = page.locator(".acpmux-composer-prompt .acpmux-md-root [contenteditable=true]");
    await composer.waitFor();
    await composer.click();
    if (draft) await page.keyboard.type(draft);
    await page.locator(".acpmux-preview-controls select").selectOption("question-pending-single");
    await page.locator(".acpmux-question").waitFor();
    // The card takes an idle keyboard in an effect after it renders; React has run its effects by
    // the time the next frame has painted.
    await installPaintedFrames(page);
    await page.evaluate(() => window.cmuxPaintFrame());
    return page;
  }

  const focusedInCard = (page: Page) =>
    page.evaluate(() => document.activeElement?.closest(".acpmux-question") !== null);

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

    test("keyboard contract: Esc skips once and claims the key without stopping the turn", async () => {
      const page = await pendingQuestion();
      await page.evaluate(() => {
        const seen: boolean[] = [];
        window.addEventListener("keydown", (event) => {
          if (event.key === "Escape") seen.push(event.defaultPrevented);
        });
        Object.assign(window, { escapesSeen: seen });
      });
      await page.keyboard.press("Escape");
      expect(await permissionCalls(page, 1)).toEqual([
        { method: "chat.permission", params: { permissionId: "perm_toolu_single", optionId: "reject_once" } },
      ]);
      expect(await page.evaluate(() => (window as unknown as { escapesSeen: boolean[] }).escapesSeen)).toEqual([true]);
      expect(await focusedInCard(page)).toBe(false);
      await page.close();
    });

    test("keyboard contract: Up/Down and Ctrl-N/P wrap, then bare Enter submits the focused option", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("ArrowUp");
      expect(await highlighted(page)).toBe("Other");
      await page.keyboard.press("ArrowDown");
      expect(await highlighted(page)).toBe("OAuth 2.0");
      await page.keyboard.press("Control+p");
      expect(await highlighted(page)).toBe("Other");
      await page.keyboard.press("Control+n");
      expect(await highlighted(page)).toBe("OAuth 2.0");
      await page.keyboard.press("Control+n");
      expect(await highlighted(page)).toBe("API keys");
      await page.keyboard.press("Enter");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: { permissionId: "perm_toolu_single", optionId: "allow_once", answers: { [prompt]: "API keys" } },
        },
      ]);
      await page.close();
    });

    test("keyboard contract: bare Enter selects the focused multi-select option and submits", async () => {
      const page = await pendingQuestion("pending-multi");
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("Enter");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: {
            permissionId: "perm_toolu_multi",
            optionId: "allow_once",
            answers: { "Which platforms should the first release support?": "iOS" },
          },
        },
      ]);
      await page.close();
    });

    test("keyboard contract: a number key chooses directly and submits", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("3");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: { permissionId: "perm_toolu_single", optionId: "allow_once", answers: { [prompt]: "Passkeys" } },
        },
      ]);
      await page.close();
    });

    test("keyboard contract: navigation from Skip returns focus to the option before Enter", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("Tab");
      expect(await page.locator(".acpmux-question-skip").evaluate((button) => button === document.activeElement)).toBe(
        true,
      );
      await page.keyboard.press("Control+n");
      expect(await highlighted(page)).toBe("API keys");
      expect(await page.locator(".acpmux-question-row:focus .acpmux-question-label").innerText()).toBe("API keys");
      await page.keyboard.press("Enter");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: { permissionId: "perm_toolu_single", optionId: "allow_once", answers: { [prompt]: "API keys" } },
        },
      ]);
      await page.close();
    });

    test("keyboard contract: Enter preserves the checked multi-select options", async () => {
      const page = await pendingQuestion("pending-multi");
      await page.keyboard.press("Space");
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("Space");
      await page.keyboard.press("Enter");
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: {
            permissionId: "perm_toolu_multi",
            optionId: "allow_once",
            answers: { "Which platforms should the first release support?": "macOS, iOS" },
          },
        },
      ]);
      await page.close();
    });

    test("one click on an option chooses it and Submit sends it", async () => {
      // Leo 2026-10-24: "just clicking it directly just automatically sends the input. So it makes
      // the skip and submit buttons redundant".
      const page = await pendingQuestion();
      await page.locator(".acpmux-question-row", { hasText: "Passkeys" }).click();
      expect(await page.locator(".acpmux-question-row", { hasText: "Passkeys" }).getAttribute("aria-checked")).toBe(
        "true",
      );
      expect(await permissionCalls(page, 0)).toEqual([]);
      await page.locator(".acpmux-question-submit").click();
      expect(await permissionCalls(page, 1)).toEqual([
        {
          method: "chat.permission",
          params: { permissionId: "perm_toolu_single", optionId: "allow_once", answers: { [prompt]: "Passkeys" } },
        },
      ]);
      await page.close();
    });

    test("a refused reply shows its error on the card and the controls work again for a retry", async () => {
      const page = await pendingQuestion();
      // acpmux refuses the first reply (the ask stays pending); the second goes through.
      await page.evaluate(() => {
        const handler = window.webkit!.messageHandlers!.agentSession!;
        const post = handler.postMessage.bind(handler);
        let refused = false;
        handler.postMessage = (message: unknown) => {
          const { method, params } = message as Call;
          if (method === "chat.permission" && !refused) {
            refused = true;
            (window as unknown as { permissionCalls: Call[] }).permissionCalls.push({ method, params });
            return Promise.resolve({ ok: false, error: { userMessage: "The agent is busy." } });
          }
          return post(message);
        };
      });
      await page.locator(".acpmux-question-row", { hasText: "API keys" }).click();
      await page.locator(".acpmux-question-submit").click();
      const error = page.locator(".acpmux-question-error");
      await error.waitFor();
      expect((await error.innerText()).replace(/\s+/g, " ").trim()).toBe(
        "Couldn’t send your answer. Try again. The agent is busy.",
      );
      expect(await page.locator(".acpmux-question").getAttribute("aria-busy")).toBeNull();
      expect(await page.locator(".acpmux-question-skip").isDisabled()).toBe(false);
      await page.locator(".acpmux-question-submit").click();
      const calls = await permissionCalls(page, 2);
      expect(calls.length).toBe(2);
      expect(calls[1]).toEqual({
        method: "chat.permission",
        params: { permissionId: "perm_toolu_single", optionId: "allow_once", answers: { [prompt]: "API keys" } },
      });
      await page.close();
    });

    test("Other textarea inherits the row font, fills its space, and shows multiline text", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("4");
      const field = page.getByRole("textbox", { name: "Other", exact: true });
      await page.keyboard.type("Signed cookies");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type("with rotation");
      const geometry = await field.evaluate((element) => {
        const field = element as HTMLTextAreaElement;
        const row = field.closest(".acpmux-question-row")!;
        const style = getComputedStyle(field);
        const rowStyle = getComputedStyle(row);
        return {
          font: style.fontFamily + "/" + style.fontSize,
          rowFont: rowStyle.fontFamily + "/" + rowStyle.fontSize,
          resize: style.resize,
          border: style.borderTopWidth,
          fill: field.getBoundingClientRect().width / row.getBoundingClientRect().width,
          clipped: field.scrollHeight > field.clientHeight,
        };
      });
      expect(geometry.font).toBe(geometry.rowFont);
      expect(geometry.resize).toBe("none");
      expect(geometry.border).toBe("0px");
      expect(geometry.fill).toBeGreaterThan(0.8);
      expect(geometry.clipped).toBe(false);
      await page.close();
    });

    test("Other takes a typed answer, which ⌘↩ sends", async () => {
      const page = await pendingQuestion();
      await page.keyboard.press("4");
      const field = page.locator(".acpmux-question-other textarea");
      await field.waitFor();
      await page.keyboard.type("Signed cookies");
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

    test("an ask that arrives while the empty composer has the keyboard takes it", async () => {
      const page = await questionArrivesMidChat();
      expect(await focusedInCard(page)).toBe(true);
      await page.keyboard.press("ArrowDown");
      expect(await highlighted(page)).toBe("API keys");
      await page.close();
    });

    test("an ask that arrives mid-draft leaves the keyboard in the composer", async () => {
      const page = await questionArrivesMidChat("half a prom");
      expect(await focusedInCard(page)).toBe(false);
      await page.keyboard.type("pt");
      const text = await page.locator(".acpmux-composer-prompt .acpmux-md-root").innerText();
      expect(text.trim()).toBe("half a prompt");
      await page.close();
    });

    test("keyboard contract: Esc in Other skips the whole ask, including earlier answers", async () => {
      const page = await pendingQuestion("pending-4-questions");
      await page.keyboard.press("1");
      expect(await page.locator(".acpmux-question-tab[aria-current=step]").innerText()).toBe("Platforms");
      await page.keyboard.press("5");
      await page.locator(".acpmux-question-other textarea").waitFor();
      await page.keyboard.type("Tauri");
      await page.keyboard.press("Escape");
      expect(await permissionCalls(page, 1)).toEqual([
        { method: "chat.permission", params: { permissionId: "perm_toolu_four", optionId: "reject_once" } },
      ]);
      await page.close();
    });

    test("a new ask arrives unfolded even when the last one was folded", async () => {
      const page = await pendingQuestion();
      await page.locator(".acpmux-question-status").click();
      expect(await page.locator(".acpmux-question").isVisible()).toBe(false);
      await page.locator(".acpmux-preview-controls select").selectOption("question-pending-multi");
      await page.locator(".acpmux-question-prompt", { hasText: "platforms" }).waitFor({ state: "attached" });
      expect(await page.locator(".acpmux-question-status").getAttribute("aria-expanded")).toBe("true");
      expect(await page.locator(".acpmux-question").isVisible()).toBe(true);
      await page.close();
    });
  });
});
