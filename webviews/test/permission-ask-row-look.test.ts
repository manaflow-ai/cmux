// A pending command's ask draws as one quiet row (Leo 2026-10-14): the command once, single line,
// in the regular-weight monospace face, cut with an ellipsis when long; small answers at the row's
// right end; a thin rim in the theme's colors and no drop shadow. The old card drew the command as
// a large bold title, wrapped, under its own heading, inside an accent border.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("permission-ask-row-look.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("permission-ask-row-look: skipping (run `bunx playwright install chromium`)");
    describe.skip("permission ask row look", () => test("chromium", () => {}));
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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const command = `B=1 bun run lint --help ${"--filter=webviews/src/agent-session ".repeat(8)}`.trim();
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
        items: [
          {
            permissionId: "permission-1",
            state: "pending",
            request: {
              toolCall: {
                toolCallId: "call-1",
                title: command,
                kind: "execute",
                rawInput: { command, cwd: "/Users/you/src/cmux" },
              },
            },
          },
        ],
      },
    ],
  };

  test("a long pending command is one regular-weight monospace line with small answers at its end", async () => {
    const page = await browser!.newPage({ viewport: { width: 640, height: 480 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/permission-panel.html`);
    await page.waitForFunction(() => "__showPermissions" in window);
    await page.evaluate(
      (shown) => (window as unknown as { __showPermissions(state: unknown): void }).__showPermissions(shown),
      state,
    );
    await page.locator(".acpmux-permission-panel button").first().waitFor();
    const seen = await page.evaluate((text) => {
      const panel = document.querySelector<HTMLElement>(".acpmux-permission-panel")!;
      // The innermost element that holds the whole command.
      const holder = [...panel.querySelectorAll<HTMLElement>("*")]
        .filter((node) => node.textContent?.includes(text))
        .at(-1)!;
      const style = getComputedStyle(holder);
      const card = panel.firstElementChild as HTMLElement;
      const cardStyle = getComputedStyle(card);
      const answers = [...panel.querySelectorAll<HTMLButtonElement>("button")].filter(
        (button) => !button.hasAttribute("aria-expanded"),
      );
      const holderBox = holder.getBoundingClientRect();
      const cardBox = card.getBoundingClientRect();
      const answerBoxes = answers.map((button) => button.getBoundingClientRect());
      return {
        mono: /mono|menlo|courier/i.test(style.fontFamily),
        weight: Number(style.fontWeight),
        oneLine: holderBox.height <= parseFloat(style.lineHeight) + 1,
        cut: style.textOverflow === "ellipsis" && holder.scrollWidth > holder.clientWidth,
        cardHeight: cardBox.height,
        rim: Math.max(
          parseFloat(cardStyle.borderTopWidth),
          parseFloat(cardStyle.borderLeftWidth),
          parseFloat(cardStyle.borderRightWidth),
        ),
        shadow: cardStyle.boxShadow,
        answerHeights: answerBoxes.map((box) => box.height),
        // The answers sit on the command's line, at the card's right end.
        answersOnRow: answerBoxes.every(
          (box) => box.top < holderBox.bottom && box.bottom > holderBox.top && box.left > holderBox.right - 1,
        ),
        rightGap: cardBox.right - Math.max(...answerBoxes.map((box) => box.right)),
      };
    }, command);
    expect(seen.mono).toBe(true);
    expect(seen.weight).toBeLessThanOrEqual(400);
    expect(seen.oneLine).toBe(true);
    expect(seen.cut).toBe(true);
    expect(seen.cardHeight).toBeLessThanOrEqual(40);
    expect(seen.rim).toBeLessThanOrEqual(1);
    expect(seen.shadow).toBe("none");
    expect(seen.answerHeights.length).toBe(3);
    for (const height of seen.answerHeights) expect(height).toBeLessThanOrEqual(24);
    expect(seen.answersOnRow).toBe(true);
    expect(seen.rightGap).toBeLessThanOrEqual(12);
    await page.close();
  });
});
