// A pending command's ask fits a narrow pane (cx-ncc.111, a regression from #20546): at 360-540px
// a long command never shortened, so the card ran past the frame and Allow / Always / Deny were
// cut off. The command ellipsizes, the card stays inside the frame, and every answer shows whole;
// when the row cannot hold them, the answers take a line of their own under the command.
//
// Real Chromium and WebKit from Playwright; CI fails the file when they cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("permission-ask-row-narrow.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("permission-ask-row-narrow: skipping (run `bunx playwright install chromium webkit`)");
    describe.skip("permission ask row narrow", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers: Record<string, Browser> = {};
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browsers.chromium = await chromium.launch({ headless: true });
    browsers.webkit = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    for (const browser of Object.values(browsers)) await browser.close();
    await vite?.close();
  });

  const command = `B=1 bun run lint --help ${"--filter=webviews/src/agent-session ".repeat(8)}`.trim();
  const item = (id: string) => ({
    permissionId: id,
    state: "pending",
    request: {
      toolCall: {
        toolCallId: `call-${id}`,
        title: command,
        kind: "execute",
        rawInput: { command, cwd: "/Users/you/src/cmux" },
      },
    },
  });
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
        turnId: "turn-1",
        revision: 1,
        state: "pending",
        decisions: ["allow_once", "allow_chat", "deny"],
        decision: null,
        items: [item("permission-1"), item("permission-2")],
      },
    ],
  };

  for (const engine of ["chromium", "webkit"]) {
    test.each([360, 420, 540])(
      `${engine}: at %ipx the ask stays in the frame with every answer whole`,
      async (width) => {
        const page = await browsers[engine]!.newPage({ viewport: { width, height: 480 } });
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/permission-panel.html`);
        await page.waitForFunction(() => "__showPermissions" in window);
        await page.evaluate(
          (shown) => (window as unknown as { __showPermissions(state: unknown): void }).__showPermissions(shown),
          state,
        );
        await page.locator(".acpmux-ask-action").first().waitFor();
        const seen = await page.evaluate(() => {
          const frame = document.documentElement.clientWidth;
          const card = document.querySelector<HTMLElement>(".acpmux-ask")!;
          const cardBox = card.getBoundingClientRect();
          const answers = [...card.querySelectorAll<HTMLElement>(".acpmux-ask-action")].map((button) => {
            const box = button.getBoundingClientRect();
            return {
              inCard: box.left >= cardBox.left - 0.5 && box.right <= cardBox.right + 0.5,
              whole: button.scrollWidth <= button.clientWidth + 1,
            };
          });
          const subjects = [...card.querySelectorAll<HTMLElement>(".acpmux-ask-subject")].map((subject) => {
            const style = getComputedStyle(subject);
            return {
              ellipsis: style.textOverflow === "ellipsis",
              shortened: subject.scrollWidth > subject.clientWidth,
              inCard: subject.getBoundingClientRect().right <= cardBox.right + 0.5,
            };
          });
          return {
            cardInFrame: cardBox.left >= -0.5 && cardBox.right <= frame + 0.5,
            pageScrolls: document.documentElement.scrollWidth > frame + 1,
            answers,
            subjects,
          };
        });
        expect(seen.cardInFrame).toBe(true);
        expect(seen.pageScrolls).toBe(false);
        expect(seen.answers.length).toBe(3);
        for (const answer of seen.answers) expect(answer).toEqual({ inCard: true, whole: true });
        for (const subject of seen.subjects) expect(subject).toEqual({ ellipsis: true, shortened: true, inCard: true });
        await page.close();
      },
    );
  }
});
