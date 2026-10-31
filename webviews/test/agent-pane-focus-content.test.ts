// PANE-FOCUS P18 (plans/cmux-next/pane-focus-DESIGN.md): on the shared page host the agent chat is
// a `PageWebView`, so each time its web view becomes first responder (a pane click outside the
// text, Cmd-Opt-Arrow, a tab switch, a relaunch) the host sends `focusContent` on the page's
// command stream (`cmux.page.command`), as it does for every page. With nothing focused in the
// chat, that must put the keyboard in the composer's prompt; a focused field or a text selection
// elsewhere in the chat keeps it. A click is the reader's own placement, though (Leo 2026-10-20, as
// in Claude desktop: "clicking outside the composer blurs it and the caret disappears"): the
// focusContent a click raises, which reaches the page just before or just after the press, leaves a
// press outside the composer unfocused, and Escape in an idle composer blurs it.
//
// The real agent pane (vite.config.acpmux-pane.mjs) with a stand-in page host (`cmuxPage`, the
// shared bridge) that answers every call and subscription and lets the test push events, plus the
// in-page mock transport. Chromium; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-focus-content.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type StandIn = { emit: (stream: string, data: unknown) => boolean };

await requireBrowserLane("agent-pane-focus-content.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-focus-content: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent pane focusContent", () => test("chromium", () => {}));
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

  /// Past an activation's claim: it waits ACTIVATION_SETTLE_MS (120 ms) and drops itself within
  /// PRESS_WINDOW_MS (400 ms) of a press (composerFocus.ts).
  const PAST_CLAIM_MS = 500;
  /// Runs the page's clock past any claim waiting to settle: a claim still to come has run after it.
  const pastClaim = (page: Page) => page.clock.runFor(PAST_CLAIM_MS);

  /// A chat on the stand-in page host, its composer shown and nothing in the page focused. The
  /// page's timers run on Playwright's clock, so a test moves past a claim's settle rather than
  /// waiting it out.
  async function chat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.clock.install();
    await page.addInitScript(() => {
      const w = window as unknown as Record<string, unknown>;
      // The shared page bridge (pageClient.ts BridgePageClient): `{t: "call"|"sub"}` envelopes
      // answered `{t: "ok"}`; the host pushes `{t: "ev"}` through `__cmuxPageReceive`.
      const subs = new Map<string, number[]>();
      const seqs = new Map<number, number>();
      let nextSub = 1;
      const postMessage = async (body: { t: string; id?: number; stream?: string; sub?: number }) => {
        if (body.t === "sub" && body.stream) {
          const sub = nextSub++;
          subs.set(body.stream, [...(subs.get(body.stream) ?? []), sub]);
          return { t: "ok", id: body.id, value: { sub } };
        }
        // An ended subscription gets no more events: `emit` counts only live listeners.
        if (body.t === "unsub")
          for (const [stream, ids] of subs)
            subs.set(
              stream,
              ids.filter((id) => id !== body.sub),
            );
        if (body.t === "call") return { t: "ok", id: body.id, value: null };
        return null;
      };
      w.webkit = { messageHandlers: { cmuxPage: { postMessage } } };
      w.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) };
      const standIn: StandIn = {
        emit(stream, data) {
          const receive = w.__cmuxPageReceive as ((envelope: unknown) => void) | undefined;
          const ids = subs.get(stream) ?? [];
          if (!receive || ids.length === 0) return false;
          for (const sub of ids) {
            const seq = (seqs.get(sub) ?? 0) + 1;
            seqs.set(sub, seq);
            receive({ t: "ev", sub, seq, data });
          }
          return true;
        },
      };
      w.__standInHost = standIn;
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt [contenteditable]").waitFor();
    // The composer's own idle claim (first paint, the ready event) runs first, and any activation's
    // claim with it, then the pane loses the keyboard: nothing in the page has focus, as when WebKit
    // restores no element.
    await page.waitForFunction(
      () => document.querySelector(".acpmux-composer-prompt [contenteditable]")?.contains(document.activeElement),
      null,
      { timeout: 5_000 },
    );
    await pastClaim(page);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    expect(await promptFocused(page)).toBe(false);
    return page;
  }

  const promptFocused = (page: Page) =>
    page.evaluate(
      () =>
        document.querySelector(".acpmux-composer-prompt [contenteditable]")?.contains(document.activeElement) === true,
    );

  /// The host's `focusContent`, as `PageWebView` sends it when its web view becomes first responder.
  const focusContent = (page: Page) =>
    page.evaluate(() =>
      (window as unknown as { __standInHost: StandIn }).__standInHost.emit("cmux.page.command", {
        command: "focusContent",
      }),
    );

  test("the host's focusContent puts the keyboard in the composer", async () => {
    const page = await chat();
    expect(await focusContent(page)).toBe(true);
    await page.waitForFunction(
      () => document.querySelector(".acpmux-composer-prompt [contenteditable]")?.contains(document.activeElement),
      null,
      { timeout: 5_000 },
    );
    await page.keyboard.type("hi");
    expect(await page.locator(".acpmux-composer-prompt [contenteditable]").evaluate((node) => node.textContent)).toBe(
      "hi",
    );
    await page.close();
  });

  /// Focuses the prompt as a click in it does.
  const focusPrompt = async (page: Page) => {
    await page.locator(".acpmux-composer-prompt [contenteditable]").click();
    expect(await promptFocused(page)).toBe(true);
  };
  /// A press on the chat's empty background, above the composer (not a control, not text).
  const pressBackground = async (page: Page) => {
    const box = (await page.locator(".acpmux-composer-box").boundingBox())!;
    await page.mouse.click(box.x + box.width / 2, Math.max(8, box.y - 120));
  };

  // The two signals a click into the pane raises in WebKit, each reaching the page after the
  // press: the host's focusContent (becomeFirstResponder) and the window's focus event.
  for (const signal of ["focusContent", "window focus"] as const)
    test(`a click outside the composer blurs it, with the click's ${signal} after the press`, async () => {
      const page = await chat();
      await focusPrompt(page);
      await pressBackground(page);
      if (signal === "focusContent") expect(await focusContent(page)).toBe(true);
      else await page.evaluate(() => window.dispatchEvent(new FocusEvent("focus")));
      await pastClaim(page);
      expect(await promptFocused(page)).toBe(false);
      // A printed key still goes into the composer: the pane keeps the keyboard.
      await page.keyboard.type("x");
      expect(await promptFocused(page)).toBe(true);
      await page.close();
    });

  test("Escape in an idle composer blurs it, and it stays blurred", async () => {
    const page = await chat();
    await focusPrompt(page);
    await page.keyboard.press("Escape");
    await pastClaim(page);
    expect(await promptFocused(page)).toBe(false);
    await page.close();
  });

  test("focusContent keeps a focused field in the chat", async () => {
    const page = await chat();
    await page.evaluate(() => {
      const field = document.createElement("input");
      field.id = "other-field";
      document.body.append(field);
      field.focus();
    });
    expect(await focusContent(page)).toBe(true);
    await pastClaim(page);
    expect(await page.evaluate(() => document.activeElement?.id)).toBe("other-field");
    await page.close();
  });

  test("focusContent keeps a text selection in the chat", async () => {
    const page = await chat();
    await page.evaluate(() => {
      const text = document.createElement("p");
      text.id = "selected-text";
      text.textContent = "copy this line";
      // Selectable like transcript text (the desktop layer makes chrome unselectable).
      text.style.userSelect = "text";
      document.body.append(text);
      const range = document.createRange();
      range.selectNodeContents(text);
      const selection = document.getSelection()!;
      selection.removeAllRanges();
      selection.addRange(range);
    });
    expect(await focusContent(page)).toBe(true);
    await pastClaim(page);
    expect(await promptFocused(page)).toBe(false);
    expect(await page.evaluate(() => document.getSelection()?.toString())).toBe("copy this line");
    await page.close();
  });
});
