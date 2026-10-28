// A pending command's ask draws as one quiet row (Leo 2026-10-14): the command once, single line,
// in the regular-weight monospace face, cut with an ellipsis when long; small answers at the row's
// right end; a thin rim in the theme's colors and no drop shadow. The old card drew the command as
// a large bold title, wrapped, under its own heading, inside an accent border.
//
// The whole row shows in the pane's bottom stack: the first build drew a flex fieldset there that
// WebKit, the app's engine, collapsed to a 15px strip with the command and answers cut off.
//
// Real Chromium and WebKit from Playwright; CI fails the file when they cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("permission-ask-row-look.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("permission-ask-row-look: skipping (run `bunx playwright install chromium webkit`)");
    describe.skip("permission ask row look", () => test("chromium", () => {}));
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

  test.each(["chromium", "webkit"])(
    "%s: a long pending command is one whole regular-weight monospace line with small answers at its end",
    async (engine) => {
      const page = await browsers[engine]!.newPage({ viewport: { width: 640, height: 480 } });
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
        const rowBox = card.querySelector<HTMLElement>(".acpmux-ask-row")!.getBoundingClientRect();
        const notes = card.querySelectorAll(".acpmux-ask-note").length;
        // The folder the command runs in, one line under the row (Codex's approval scope, #24595).
        const scopes = card.querySelectorAll(".acpmux-ask-scope").length;
        const answerBoxes = answers.map((button) => button.getBoundingClientRect());
        return {
          mono: /mono|menlo|courier/i.test(style.fontFamily),
          weight: Number(style.fontWeight),
          oneLine: holderBox.height <= parseFloat(style.lineHeight) + 1,
          cut: style.textOverflow === "ellipsis" && holder.scrollWidth > holder.clientWidth,
          rowHeight: rowBox.height,
          // The card is the row plus its one-line notes (what Always grants) and scope, nothing more.
          cardExtra: cardBox.height - rowBox.height - (notes + scopes) * 24,
          notes,
          scopes,
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
          // Nothing of the row is cut: the panel holds all of it, and the line is its full height.
          panelScrolls: panel.scrollHeight > panel.clientHeight + 1,
          holderHeight: holderBox.height,
        };
      }, command);
      expect(seen.mono).toBe(true);
      expect(seen.weight).toBeLessThanOrEqual(400);
      expect(seen.oneLine).toBe(true);
      expect(seen.cut).toBe(true);
      expect(seen.rowHeight).toBeLessThanOrEqual(40);
      expect(seen.rowHeight).toBeGreaterThanOrEqual(28);
      expect(seen.notes).toBe(1);
      expect(seen.scopes).toBe(1);
      expect(seen.cardExtra).toBeLessThanOrEqual(10);
      expect(seen.panelScrolls).toBe(false);
      expect(seen.holderHeight).toBeGreaterThanOrEqual(14);
      expect(seen.rim).toBeLessThanOrEqual(1);
      expect(seen.shadow).toBe("none");
      expect(seen.answerHeights.length).toBe(3);
      for (const height of seen.answerHeights) expect(height).toBeLessThanOrEqual(24);
      expect(seen.answersOnRow).toBe(true);
      expect(seen.rightGap).toBeLessThanOrEqual(12);
      await page.close();
    },
  );

  // The app's WebKit treats the bottom stack's flexed height as definite and resolved the panel's
  // 45% cap against it: the stack is the panel's own height, so a lone ask showed under half of
  // itself (the row cut through its answers, the scope note hidden; a capture mini, 2026-10-14).
  // Playwright's engines leave that height indefinite, so the test pins the stack to its laid-out
  // height, the size WebKit resolves against.
  test.each(["chromium", "webkit"])("%s: the whole ask shows when the stack's height is definite", async (engine) => {
    const page = await browsers[engine]!.newPage({ viewport: { width: 640, height: 480 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/permission-panel.html`);
    await page.waitForFunction(() => "__showPermissions" in window);
    await page.evaluate(
      (shown) => (window as unknown as { __showPermissions(state: unknown): void }).__showPermissions(shown),
      state,
    );
    await page.locator(".acpmux-permission-panel button").first().waitFor();
    const seen = await page.evaluate(() => {
      const stack = document.querySelector<HTMLElement>(".acpmux-asks-stack")!;
      stack.style.height = `${stack.getBoundingClientRect().height}px`;
      const panel = document.querySelector<HTMLElement>(".acpmux-permission-panel")!;
      const card = panel.firstElementChild as HTMLElement;
      return {
        panelScrolls: panel.scrollHeight > panel.clientHeight + 1,
        cardShown: panel.getBoundingClientRect().bottom >= card.getBoundingClientRect().bottom - 1,
      };
    });
    expect(seen).toEqual({ panelScrolls: false, cardShown: true });
    await page.close();
  });
});
