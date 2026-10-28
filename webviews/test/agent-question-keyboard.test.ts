// Exercise QuestionCard's callback directly so free-text keyboard behavior is independent of transport mapping.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-question-keyboard.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const harness = path.join(webviews, "test/question-keyboard-harness.tsx");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-preview.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
      plugins: [
        {
          name: "question-keyboard-harness",
          resolveId(id) {
            if (id === "/question-keyboard-harness.tsx") return harness;
          },
          load(id) {
            if (id !== harness) return;
            return `
            import React from "react";
            import { createRoot } from "react-dom/client";
            import { QuestionCard } from "../src/agent-session/acpmux/question/QuestionCard";
            import question from "../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";
            window.questionReplies = [];
            const host = document.createElement("main");
            document.body.replaceChildren(host);
            createRoot(host).render(React.createElement(QuestionCard, {
              question,
              onReply(reply) { window.questionReplies.push(reply); },
            }));
          `;
          },
        },
      ],
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    await warmViteServer(vite, "/question-keyboard-harness.tsx");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function card(): Promise<Page> {
    const page = await browser.newPage();
    page.setDefaultTimeout(5_000);
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?fixture=worked-turn`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.addScriptTag({ type: "module", url: `http://127.0.0.1:${port}/question-keyboard-harness.tsx` });
    await page.locator(".acpmux-question-row:focus").waitFor();
    return page;
  }
  const replies = (page: Page) =>
    page.evaluate(() => (window as unknown as { questionReplies: unknown[] }).questionReplies);

  test("keyboard callback: Other supports Shift-Enter newline and Enter submits its text once", async () => {
    const page = await card();
    await page.keyboard.press("4");
    const field = page.getByRole("textbox", { name: "Other", exact: true });
    await field.waitFor();
    await page.keyboard.type("Signed cookies");
    await page.keyboard.press("Shift+Enter");
    await page.keyboard.type("with rotation");
    expect(await field.inputValue()).toBe("Signed cookies\nwith rotation");
    expect(await replies(page)).toEqual([]);
    await page.keyboard.press("Enter");
    await page.waitForFunction(
      () => (window as unknown as { questionReplies: unknown[] }).questionReplies.length === 1,
    );
    expect(await replies(page)).toEqual([
      {
        session: "sess_claude_1",
        permissionId: "perm_toolu_single",
        optionId: "allow_once",
        answers: { "Which auth method should the API use?": "Signed cookies\nwith rotation" },
      },
    ]);
    await field.dispatchEvent("keydown", { key: "Enter", repeat: true });
    expect((await replies(page)).length).toBe(1);
    await page.close();
  });

  test("keyboard callback: IME confirmation never submits or skips", async () => {
    const page = await card();
    await page.keyboard.press("4");
    const field = page.getByRole("textbox", { name: "Other", exact: true });
    await field.waitFor();
    await page.keyboard.type("候補");
    await field.dispatchEvent("keydown", { key: "Enter", isComposing: true });
    await field.dispatchEvent("keydown", { key: "Enter", keyCode: 229 });
    await field.dispatchEvent("keydown", { key: "Escape", isComposing: true });
    expect(await replies(page)).toEqual([]);
    expect(await field.inputValue()).toBe("候補");
    await page.keyboard.press("Enter");
    await page.waitForFunction(
      () => (window as unknown as { questionReplies: unknown[] }).questionReplies.length === 1,
    );
    expect((await replies(page)).length).toBe(1);
    await page.close();
  });
});
