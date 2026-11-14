// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A sent prompt holding a long inspector pick (conversation/SentUIPick.tsx) under the prompt's fold
// (conversation/PromptText.tsx). Leo, 2026-11-08: "clicking it should be able to show the raw/full
// thing... idk how possible it'd be to also be able to have a well-designed button to click to
// re-collapse it too."
// - Opening the pick's chip opens the prompt's fold, and its report makes the prompt long.
// - Collapse folds the chip back, and a prompt short without its report has no fold: it never flips
//   between open and folded. The fold's two states measure the same boxes (PromptText.tsx
//   laidOutHeight), so what a box clips inside the prompt counts the same in both.
// - With the chip left open, Show less folds the prompt once and it stays folded.
//
// Before (router review F1 at e87508fa): the chip kept its folded report drawn, clipped by its
// panel. Drawn whole, the prompt's lines counted that report and read long; clamped, its box did not
// and read short, so Show less flipped the fold until React's update limit (the pane's error
// boundary took the transcript).
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux that holds the chat's history.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("ui-pick-sent-fold.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("ui-pick-sent-fold: skipping (run `bunx playwright install chromium`)");
    describe.skip("sent pick fold", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000d4";
  const START = Date.UTC(2026, 10, 9, 9, 0, 0);
  // A pick as the composer sends it (attachments.ts promptText): its name over its report in a
  // fence. The report is far longer than the prompt's twenty folded lines.
  const REPORT = [
    "cmux NEXT app-owned webview selection",
    "Component: span",
    "Source: unavailable",
    "Selector: .cv-li__text",
    "Text: the Cloud version-check and Cloud Desktop fixes;",
    ...Array.from({ length: 60 }, (_, index) => `Computed style ${index + 1}: "margin-${index + 1}": "0px"`),
    'DOM: <span class="cv-li__text">the Cloud version-check and Cloud Desktop fixes;</span>',
  ].join("\n");
  // Ten lines of question: long with the chip open, short with it closed.
  const QUESTION = Array.from({ length: 10 }, (_, index) => `Line ${index + 1}: why is this list item cut off?`).join(
    "\n",
  );
  const PROMPT = `${QUESTION}\n\nUI: span\n\`\`\`\n${REPORT}\n\`\`\``;
  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: PROMPT, promptId: "prompt-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Its row clips the label.")],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Fix it", promptId: "prompt-2" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Done.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "Pick",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 2,
    updatedAt: START,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the transcript.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Fix it", { exact: true }).waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Opens the pick's chip in the sent prompt, then folds the chip back (`collapse`) or leaves it
  /// open, then clicks the prompt's Show less when it has one, and reads how the fold settled.
  async function foldAfterPick(collapse: boolean) {
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    try {
      await page.goto(url());
      await page.getByText("Fix it", { exact: true }).waitFor();
      const row = page.locator("article[data-row-id='user-1']");
      await row.scrollIntoViewIfNeeded();
      const chip = row.locator('.cv-user__text [data-chip-kind="ui"]');
      await chip.waitFor();
      const face = chip.locator("button[aria-expanded]");
      /// Until nothing animates and the bubble held still since the frame before.
      const settled = () =>
        page.waitForFunction(
          () => {
            const bubble = document.querySelector<HTMLElement>("article[data-row-id='user-1'] .cv-user__bubble");
            const at = bubble ? `${bubble.getBoundingClientRect().height}` : "";
            const was = (window as { bubbleAt?: string }).bubbleAt;
            (window as { bubbleAt?: string }).bubbleAt = at;
            return was === at && document.getAnimations().every((animation) => animation.playState !== "running");
          },
          undefined,
          { timeout: 30_000, polling: "raf" },
        );
      const toggle = row.locator(".cv-user__more");
      const fold = () =>
        page.evaluate(() => {
          const node = document.querySelector("article[data-row-id='user-1']");
          return {
            clamped: node?.querySelector(".cv-user__text")?.classList.contains("is-clamped") ?? false,
            more: node?.querySelector(".cv-user__more")?.getAttribute("aria-expanded") ?? "none",
          };
        });

      await settled();
      // The question and the closed chip are short: no fold.
      expect(await fold()).toEqual({ clamped: false, more: "none" });
      await face.click();
      await settled();
      expect(await face.getAttribute("aria-expanded")).toBe("true");
      // Opened, the report makes the prompt long: its fold is open with Show less under it.
      expect(await fold()).toEqual({ clamped: false, more: "true" });
      if (collapse) {
        await chip.getByRole("button", { name: "Collapse" }).click();
        await settled();
        expect(await face.getAttribute("aria-expanded")).toBe("false");
      }

      // Each flip of the fold from here on: the text's clamp and the toggle's state.
      await page.evaluate(() => {
        const row = document.querySelector("article[data-row-id='user-1']")!;
        const flips: string[] = [];
        (window as { flips?: string[] }).flips = flips;
        const read = () => ({
          clamped: row.querySelector(".cv-user__text")?.classList.contains("is-clamped") ?? false,
          more: row.querySelector(".cv-user__more")?.getAttribute("aria-expanded") ?? "none",
        });
        let last = read();
        new MutationObserver(() => {
          const now = read();
          if (now.clamped !== last.clamped) flips.push(`clamp:${now.clamped}`);
          if (now.more !== last.more) flips.push(`more:${now.more}`);
          last = now;
        }).observe(row, {
          subtree: true,
          attributes: true,
          attributeFilter: ["class", "aria-expanded"],
          childList: true,
        });
      });
      const less = (await toggle.count()) > 0 && (await toggle.getAttribute("aria-expanded")) === "true";
      if (less) await toggle.click();
      await settled();
      // A few more frames for a ResizeObserver round to disagree, if it would.
      await page.evaluate(
        () =>
          new Promise<void>((resolve) => {
            let left = 10;
            // raf-read: it reads nothing in the frame; it only lets ten frames of ResizeObserver rounds run.
            const step = () => (--left ? requestAnimationFrame(step) : resolve());
            requestAnimationFrame(step);
          }),
      );
      // A loop ends in React's update limit and the pane's error boundary: no row to read.
      expect(errors.filter((error) => /Maximum update depth/i.test(error))).toEqual([]);
      const flips = await page.evaluate(() => (window as { flips?: string[] }).flips ?? []);
      const state = await fold();
      // And it still reads: the chip opens (again) with its whole report.
      if (collapse) await face.click();
      await settled();
      expect(await face.getAttribute("aria-expanded")).toBe("true");
      expect(await chip.locator('[role="document"]').textContent()).toContain("DOM: <span class=");
      return { less, flips, state };
    } finally {
      await page.close();
    }
  }

  test("a sent pick opened then collapsed leaves a short prompt with no fold, never a flipping one", async () => {
    const { less, flips, state } = await foldAfterPick(true);
    // Folded back, the chip's clipped report is not the prompt's height: no Show less to press.
    expect({ less, state }).toEqual({ less: false, state: { clamped: false, more: "none" } });
    // One change at most: the toggle going away with the report, never back.
    expect(flips).toEqual(flips.length ? ["more:none"] : []);
  });

  test("Show less with a long sent pick open folds the prompt once and it stays folded", async () => {
    const { less, flips, state } = await foldAfterPick(false);
    expect(less).toBe(true);
    expect(state).toEqual({ clamped: true, more: "false" });
    // One fold: the clamp going on and the toggle reading Show more, never back.
    expect([...flips].sort()).toEqual(["clamp:true", "more:false"]);
  });
});
