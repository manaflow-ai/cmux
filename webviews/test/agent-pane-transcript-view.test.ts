// The chat menu's Transcript view in the real agent pane (Leo, 2026-10-29: "i like these kinds of
// settings from claude code desktop..."). The page is the pane's dev entry with its browser host,
// talking JSON-RPC over a WebSocket to a stand-in acpmux daemon that serves one finished recorded
// chat (replay/replayFixture.ts: a thought, a read, test runs and an edit).
//
// - Normal is today's transcript: the finished turn folds its work under "Worked for".
// - Thinking, picked from the menu, opens that fold: the thought shows, each call's output stays folded.
// - Verbose also opens each call to its output.
// - Closing the turn's fold by hand in Verbose keeps it closed there; Normal keeps its own folds.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { REPLAY_SESSION, replayFixtureEvents } from "../src/agent-session/acpmux/replay/replayFixture";

await requireBrowserLane("agent-pane-transcript-view.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-transcript-view: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript view", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const ANSWER = "All 12 tests in api/client.test.ts pass.";

  // The recorded thought is a short, quick one, which every view hides (thoughts.ts isQuietThought):
  // give it the length of a real one so Thinking has a thought to open.
  const THOUGHT =
    "Read the retry helper first. The test retries a request that fails twice, so the helper's " +
    "attempt count and its backoff decide whether the third try lands before the assertion runs.";
  const events = replayFixtureEvents().map((event) =>
    JSON.parse(JSON.stringify(event).replace("Read the retry helper first.", THOUGHT)),
  );
  const summary = {
    sessionId: REPLAY_SESSION,
    cwd: "/home/dev/api",
    title: "Fix the flaky retry test",
    harness: "claude",
    status: "idle",
    updatedAt: events.at(-1)!.at,
  };

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: events.length, events };
      case "_acpmux/events": {
        const after = Number(params.afterSeq ?? 0);
        const before = Number(params.beforeSeq ?? Number.POSITIVE_INFINITY);
        const page = events.filter((event) => event.seq > after && event.seq < before);
        return { events: page, hasMore: false, lastSeq: events.length };
      }
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const pageUrl = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${REPLAY_SESSION}`;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
            );
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
    // again if it stalls, so the test times only the menu.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      await warm.goto(pageUrl());
      try {
        await warm.getByText(ANSWER).waitFor({ timeout: 25_000 });
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

  async function pick(page: Page, view: string): Promise<void> {
    await page.getByRole("button", { name: "Chat actions" }).click();
    await page.getByRole("menuitem", { name: "Transcript view" }).click();
    await page.getByRole("menuitemradio", { name: view }).click();
    await page.getByRole("menu").first().waitFor({ state: "detached" });
  }

  describe("transcript view", () => {
    test("letters typed into the chat menu are its typeahead: they never rename, fork, archive nor change the view", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
      await page.goto(pageUrl());
      await page.getByText(ANSWER).waitFor();
      const stored = () => page.evaluate(() => localStorage.getItem("cmux.acpmux.transcriptView"));
      const before = await stored();
      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menu").first().waitFor();
      // The ··· menu has no row letters (only the title menu has, #25661): a bare "r", "a" or "f" and
      // "tr" (Transcript view), "ma" (Mark as Unread), "fo" (Fork…), "ar", "re" only move the focus.
      for (const word of ["r", "a", "f", "tr", "ma", "fo", "ar", "re"]) {
        await page.keyboard.type(word, { delay: 40 });
        // fixed-wait: each word must start its own typeahead sequence (menuLetters.ts TYPEAHEAD_MS, 600 ms).
        await page.waitForTimeout(700);
      }
      const menuOpen = (await page.getByRole("menu").count()) > 0;
      const renaming = await page.locator('input[aria-label*="Rename" i], [data-renaming]').count();
      expect({ menuOpen, renaming, view: await stored() }).toEqual({ menuOpen: true, renaming: 0, view: before });
      await page.close();
    });

    // The ··· menu is already full height: Transcript view takes Text & Width's row (its submenu ends
    // with Text & Width…), so Archive stays on screen. This chat's menu is 647 px tall (21 rows) and
    // opens 32 px down: a 690 px pane holds it with less than one row to spare, so a row more (the
    // review of #28782 at 7f8dfad8) pushes Archive out of view and fails here.
    test("the chat menu still shows Archive; Transcript view and Text & Width are in one submenu", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 690 } });
      await page.goto(pageUrl());
      await page.getByText(ANSWER).waitFor();
      await page.getByRole("button", { name: "Chat actions" }).click();
      const menu = page.locator(".acpmux-chat-menu-popover").first();
      await menu.waitFor();
      const archive = menu.getByRole("menuitem", { name: /^Archive/ });
      await archive.waitFor({ state: "attached" });
      const fit = await page.evaluate(() => {
        const popup = document.querySelector<HTMLElement>(".acpmux-chat-menu-popover")!;
        const row = [...popup.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((each) =>
          each.textContent?.trim().startsWith("Archive"),
        )!;
        const shown = popup.getBoundingClientRect();
        const box = row.getBoundingClientRect();
        return {
          inView: popup.scrollTop === 0 && box.bottom <= shown.bottom + 0.5 && box.bottom <= window.innerHeight,
          detail: `row ${Math.round(box.top)}-${Math.round(box.bottom)}, menu ${Math.round(shown.top)}-${Math.round(shown.bottom)} (scrolls ${popup.scrollHeight}/${popup.clientHeight}), window ${window.innerHeight}`,
        };
      });
      const topRows = await menu.getByRole("menuitem").allTextContents();
      if (!fit.inView) throw new Error(`Archive is out of view: ${fit.detail}; rows: ${topRows.join(" | ")}`);
      // Text & Width is no row of its own any more: it ends the Transcript view submenu.
      expect(topRows.some((row) => row.trim().startsWith("Text & Width"))).toBe(false);

      await menu.getByRole("menuitem", { name: "Transcript view" }).click();
      const radios = page.getByRole("menuitemradio");
      await radios.first().waitFor();
      // Each view by its accessible name (the picked one's check is drawn inside its row).
      for (const view of ["Normal", "Thinking", "Verbose"])
        expect(await page.getByRole("menuitemradio", { name: view, exact: true }).count()).toBe(1);
      await page.getByRole("menuitem", { name: /^Text & Width/ }).click();
      await page.locator(".acpmux-display").waitFor();
      await page.close();
    });

    // Verbose opens every Shell block; Wrap lines is one choice for all of them (blockWrap.ts), so it
    // never repeats on every block at rest: a block shows it on hover or focus, and the Transcript
    // view submenu has it once (the review of #28782 at 13b0b525).
    test("Verbose shows no Wrap lines on every Shell block at rest; the submenu's Wrap lines flips them all", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
      await page.goto(pageUrl());
      await page.getByText(ANSWER).waitFor();
      await pick(page, "Verbose");
      const shells = page.locator(".cv-shell");
      await shells.nth(1).waitFor();
      await page.mouse.move(1, 1);
      // The Wrap lines buttons a reader sees: drawn, and not see-through.
      const countShown = () =>
        [...document.querySelectorAll<HTMLElement>('.cv-shell button[aria-label="Wrap lines"]')].filter((button) => {
          const box = button.getBoundingClientRect();
          return box.width > 0 && Number(getComputedStyle(button).opacity) > 0.01;
        }).length;
      const shownWraps = () => page.evaluate(countShown);
      // The buttons fade on the shared hover tokens (conversation.css, --cv-actions-in/out and the
      // in-delay), so each read waits for its fade to settle rather than taking the first frame.
      const settle = (want: number) =>
        page
          .waitForFunction(
            (shown) =>
              [...document.querySelectorAll<HTMLElement>('.cv-shell button[aria-label="Wrap lines"]')].filter(
                (button) => button.getBoundingClientRect().width > 0 && Number(getComputedStyle(button).opacity) > 0.01,
              ).length === shown,
            want,
            { timeout: 2_000 },
          )
          .catch(() => undefined);
      await settle(0);
      const atRest = { shells: (await shells.count()) >= 2, wraps: await shownWraps() };
      // Hovering a block shows its own.
      await shells.first().hover();
      await settle(1);
      const hovered = await shownWraps();
      await page.mouse.move(1, 1);
      expect({ atRest, hovered }).toEqual({ atRest: { shells: true, wraps: 0 }, hovered: 1 });

      const wrapOf = () => page.locator(".cv-shell__body").first().getAttribute("data-wrap");
      const before = await wrapOf();
      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menuitem", { name: "Transcript view" }).click();
      const toggle = page.getByRole("menuitemcheckbox", { name: "Wrap lines" });
      expect(await toggle.getAttribute("aria-checked")).toBe(before);
      await toggle.click();
      await page.waitForFunction(
        (was) =>
          [...document.querySelectorAll(".cv-shell__body")].every((body) => body.getAttribute("data-wrap") !== was),
        before,
      );
      // A second click in the same open menu flips it back: the row reads the choice when clicked,
      // not the one the menu opened with (HQ#5600).
      await toggle.click();
      await page.waitForFunction(
        (was) =>
          [...document.querySelectorAll(".cv-shell__body")].every((body) => body.getAttribute("data-wrap") === was),
        before,
      );
      expect(await toggle.getAttribute("aria-checked")).toBe(before);
      await page.close();
    });

    test("a replay of the chat draws under the chat's view", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
      await page.addInitScript(() => localStorage.setItem("cmux.experiments", '{"session-replay":"on"}'));
      await page.goto(pageUrl());
      await page.getByText(ANSWER).waitFor();
      await pick(page, "Verbose");
      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menuitem", { name: "Replay" }).click();
      const replay = page.locator(".acpmux-replay");
      await replay.waitFor();
      await replay.getByRole("button", { name: "Pause", exact: true }).click();
      // Scrub to the end of the recording (0:17): every call has run by then.
      await replay.getByRole("slider", { name: "Replay position" }).fill("17700");
      const calls = replay.locator(".cv-tools .cv-tool.is-toggle:not(.cv-thought)");
      await calls.first().waitFor();
      const open = replay.locator('.cv-tools .cv-tool.is-toggle:not(.cv-thought)[aria-expanded="true"]');
      await open.first().waitFor();
      expect((await open.count()) === (await calls.count())).toBe(true);
      await page.close();
    });

    test("Thinking and Verbose from the chat menu open a finished turn's work; Normal folds it", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
      await page.goto(pageUrl());
      await page.getByText(ANSWER).waitFor();
      const worked = page.locator(".cv-worked").first();
      const thought = page.locator(".cv-thought");
      // Each call's own row: a command (CommandRow) or another tool (ToolRow), each opening its output.
      const commands = page.locator(".cv-tools .cv-tool.is-toggle:not(.cv-thought)");
      const openCommands = page.locator('.cv-tools .cv-tool.is-toggle:not(.cv-thought)[aria-expanded="true"]');
      const normal = {
        worked: await worked.getAttribute("aria-expanded"),
        thoughts: await thought.count(),
        commands: await commands.count(),
      };

      await pick(page, "Thinking");
      // What the pane shows once the pick lands, so a miss says where it stopped.
      await page
        .locator('.cv-worked[aria-expanded="true"]')
        .first()
        .waitFor({ timeout: 10_000 })
        .catch(() => undefined);
      const picked = await page.evaluate(() => ({
        stored: localStorage.getItem("cmux.acpmux.transcriptView"),
        worked: [...document.querySelectorAll(".cv-worked")].map((node) => node.getAttribute("aria-expanded")),
        rows: [...document.querySelectorAll("[data-row-kind], .cv-tool")].length,
        classes: [
          ...new Set(
            [...document.querySelectorAll("[class*='cv-']")].flatMap((node) =>
              [...node.classList].filter((name) => name.startsWith("cv-")),
            ),
          ),
        ].join(" "),
        text: (document.querySelector(".acpmux-main") as HTMLElement | null)?.innerText.slice(0, 700),
      }));
      if (!(await thought.count())) throw new Error(`Thinking drew no thought: ${JSON.stringify(picked)}`);
      const thinking = {
        worked: await worked.getAttribute("aria-expanded"),
        thoughts: (await thought.count()) > 0,
        commands: (await commands.count()) > 0,
        // Only what opens on its own in every view (a failed call's output); Verbose opens the rest.
        someClosed: (await openCommands.count()) < (await commands.count()),
      };

      await pick(page, "Verbose");
      await openCommands.first().waitFor();
      const verbose = { open: (await openCommands.count()) === (await commands.count()) };

      // The reader's own close of the turn holds in Verbose: a finished turn has one fold (turns.ts
      // foldSegments), so closing it takes every call out of sight.
      const before = await commands.count();
      await worked.click();
      await page.waitForFunction(
        (shown) => document.querySelectorAll(".cv-tools .cv-tool.is-toggle:not(.cv-thought)").length < shown,
        before,
      );
      const closedByHand = {
        worked: await worked.getAttribute("aria-expanded"),
        fewer: (await commands.count()) < before,
      };

      await pick(page, "Normal");
      const backToNormal = {
        worked: await worked.getAttribute("aria-expanded"),
        thoughts: await thought.count(),
        commands: await commands.count(),
      };

      expect({ normal, thinking, verbose, closedByHand, backToNormal }).toEqual({
        normal: { worked: "false", thoughts: 0, commands: 0 },
        thinking: { worked: "true", thoughts: true, commands: true, someClosed: true },
        verbose: { open: true },
        closedByHand: { worked: "false", fewer: true },
        backToNormal: { worked: "false", thoughts: 0, commands: 0 },
      });
      await page.close();
    });
  });
});
