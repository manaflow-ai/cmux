// cmux-web-test-timeout: 240
// Find in Chat on the real agent pane (src/agent-session/acpmux, `?mock`: the in-page mock daemon
// and its seeded worked turn), driven the way the app drives it: the `chat.find` page action that
// Find (Cmd-F) sends to an agent pane, then the bar's own keys.
// - the bar opens with the query and counts the transcript's matches;
// - the matches draw as custom highlights, with the current one apart;
// - Enter and Shift-Enter step through the matches, wrapping, and the current one scrolls into view;
// - Escape closes the bar and clears the highlights;
// - the app's Find, Find Next and Hide Find bridge commands do the same.
//
// Headless Chromium from Playwright; skipped where it is not installed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { stopDevServer } from "./support/devServer";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("chat-find.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  let installed = true;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    installed = false;
    console.warn("chat-find: skipping (run `bunx playwright install chromium`)");
  }

  let server: ChildProcess | null = null;
  let browser: Browser | null = null;
  let base = "";

  beforeAll(async () => {
    if (!installed) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(
      path.join(webviews, "node_modules/.bin/vp"),
      ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port), "--strictPort"],
      { cwd: webviews, stdio: ["ignore", "pipe", "pipe"] },
    );
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    await warmDevServer(base, "/?mock");
    browser = await chromium.launch({ headless: true });
  }, 240_000);

  afterAll(async () => {
    await browser?.close();
    stopDevServer(server);
  });

  /** The bar's count, the highlights drawn and the current match's text. */
  async function state(page: Page) {
    return page.evaluate(() => {
      const highlights = (CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights;
      const active = [...(highlights.get("acpmux-find-active") ?? [])];
      return {
        open: document.querySelector(".acpmux-find") !== null,
        count: document.querySelector(".acpmux-find .find-pill__count")?.textContent ?? "",
        others: highlights.get("acpmux-find")?.size ?? 0,
        active: active.map((range) => range.toString()),
        // The current match is inside the transcript's viewport.
        inView: active.every((range) => {
          const box = range.getBoundingClientRect();
          const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          return box.top >= view.top && box.bottom <= view.bottom;
        }),
      };
    });
  }

  /** Waits (up to 5 s) for the current match to sit in the transcript's viewport: a match in a
   * closed fold opens it first, and its rows measure before the scroll lands. */
  async function settleInView(page: Page) {
    await page
      .waitForFunction(
        () => {
          const active = [
            ...((CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights.get("acpmux-find-active") ?? []),
          ];
          const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          return (
            active.length > 0 &&
            active.every((range) => {
              const box = range.getBoundingClientRect();
              return box.top >= view.top && box.bottom <= view.bottom;
            })
          );
        },
        null,
        { timeout: 5_000 },
      )
      .catch(() => undefined);
  }

  async function openChat(page: Page) {
    await page.goto(`${base}/?mock`);
    // The seeded worked turn's reply is drawn.
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-scroll [data-row-id]").length > 1, null, {
      timeout: 30_000,
    });
  }

  describe("Find in Chat", () => {
    test("chat.find opens the bar, counts and highlights matches, steps, and closes", async () => {
      if (!installed) return;
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await openChat(page);
      const query = await page.evaluate(() => {
        // A word of the seeded transcript's text, so the counts below are the page's, not ours.
        const text = document.querySelector(".acpmux-scroll [data-row-id]")?.textContent ?? "";
        return (text.match(/[A-Za-z]{5,}/) ?? [""])[0];
      });
      expect(query).not.toBe("");

      const opened = await page.evaluate(
        (text) =>
          typeof window.cmuxAcpmuxActions?.["chat.find"] === "function"
            ? window.cmuxAcpmuxActions["chat.find"]({ text }).then(() => true)
            : false,
        query,
      );
      expect(opened).toBe(true);
      await page.waitForSelector(".acpmux-find .find-pill__field");
      expect(await page.evaluate(() => (document.activeElement as HTMLInputElement | null)?.value)).toBe(query);

      const first = await state(page);
      const total = Number(/of (\d+)/.exec(first.count)?.[1] ?? 0);
      expect(first.count).toMatch(/^1 of \d+$/);
      expect(total).toBeGreaterThan(0);
      expect(first.active).toEqual([expect.stringMatching(new RegExp(`^${query}$`, "i"))]);

      // Enter steps forward; Shift-Enter steps back, wrapping past the first match.
      await page.keyboard.press("Enter");
      expect((await state(page)).count).toBe(`${Math.min(2, total)} of ${total}`);
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.press("Shift+Enter");
      await settleInView(page);
      const last = await state(page);
      expect(last.count).toBe(`${total} of ${total}`);
      expect(last.inView).toBe(true);

      // A query that is nowhere says so.
      await page.fill(".acpmux-find .find-pill__field", "zzqqxxnotintranscript");
      const none = await state(page);
      expect(none.count).toBe("No results");
      expect(none.active).toEqual([]);
      expect(none.others).toBe(0);

      await page.keyboard.press("Escape");
      const closed = await state(page);
      expect(closed.open).toBe(false);
      expect(closed.active).toEqual([]);
      expect(closed.others).toBe(0);

      // The app's Find commands arrive as bridge commands: Find opens the bar again with the last
      // query, Find Next steps, Hide Find closes.
      await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("find"));
      await page.waitForSelector(".acpmux-find .find-pill__field");
      await page.fill(".acpmux-find .find-pill__field", query);
      await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("findNext"));
      expect((await state(page)).count).toBe(`${Math.min(2, total)} of ${total}`);
      await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("hideFind"));
      expect((await state(page)).open).toBe(false);
      await page.close();
    });

    // Codex desktop app parity (cx-ncc.70): Find reads the work too. The seeded turn has ended, so
    // its commands and edits sit in a closed "Worked for" fold; a match there opens what holds it
    // and scrolls it into view.
    test("finds command output and edit diffs inside a closed Worked for fold", async () => {
      if (!installed) return;
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await openChat(page);
      // A loaded machine (#19761 CI): the fold the match opens and the rows above it measure long
      // after the match is first drawn, and Find still lands it in view.
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: 40 });
      // Only in the test command's output: found, its group opened, highlighted and in view.
      await page.evaluate((text) => window.cmuxAcpmuxActions?.["chat.find"]?.({ text }), "1504.40ms");
      await page.waitForSelector(".acpmux-find .find-pill__field");
      const activeIs = (text: string) =>
        page
          .waitForFunction(
            (needle) =>
              [
                ...((CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights.get("acpmux-find-active") ??
                  []),
              ]
                .map(String)
                .some((range) => range.toLowerCase() === needle.toLowerCase()),
            text,
            { timeout: 10_000 },
          )
          .catch(() => undefined);
      await activeIs("1504.40ms");
      await settleInView(page);
      const output = await state(page);
      expect(output.count).toBe("1 of 1");
      expect(output.active).toEqual(["1504.40ms"]);
      expect(output.inView).toBe(true);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });

      // Only in the edit of upload.test.ts: found, and its edits group opens on the diff. (The diff
      // draws in @pierre/diffs' shadow root, where the page's highlights do not reach.)
      await page.fill(".acpmux-find .find-pill__field", "failNext");
      await page.waitForFunction(
        () =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-scroll button[aria-expanded]")].some(
            (button) =>
              (button.textContent ?? "").startsWith("Edited 3 files") &&
              button.getAttribute("aria-expanded") === "true",
          ),
        null,
        { timeout: 10_000 },
      );
      expect((await state(page)).count).toBe("1 of 1");

      // The counter and the highlight agree: each step through a command's matches lands on a
      // different drawn match (a group's summary line and a call's title are not counted).
      await page.fill(".acpmux-find .find-pill__field", "bun test");
      const total = Number(/of (\d+)/.exec((await state(page)).count)?.[1] ?? 0);
      expect(total).toBeGreaterThan(1);
      const seen = new Set<string>();
      for (let step = 0; step < total; step += 1) {
        await settleInView(page);
        seen.add(
          await page.evaluate(() => {
            const range = [
              ...((CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights.get("acpmux-find-active") ??
                []),
            ][0];
            const box = range?.getBoundingClientRect();
            const scroller = document.querySelector(".acpmux-scroll")!;
            return box ? `${Math.round(box.top + scroller.scrollTop)}:${Math.round(box.left)}` : "none";
          }),
        );
        await page.keyboard.press("Enter");
      }
      expect(seen.has("none")).toBe(false);
      expect(seen.size).toBe(total);
      await page.close();
    });

    // A starved page (#19761, op-next-cmdclick's runs on 10-13) measures the fold Find opened for
    // seconds, and each late measure pushes the match down. Find holds it in view until it stops
    // moving, not for a fixed 600 ms: here the match moves down for 2 s from when it is drawn, inside
    // its command's capped output (a scroller of its own), so the hold must scroll that box too.
    test("keeps a Find match in view while what is above it keeps measuring", async () => {
      if (!installed) return;
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await openChat(page);
      await page.evaluate((text) => window.cmuxAcpmuxActions?.["chat.find"]?.({ text }), "1504.40ms");
      await page.waitForSelector(".acpmux-find .find-pill__field");
      // As soon as the match is drawn, while Find is still bringing it into view.
      await page.waitForFunction(
        () =>
          ((CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights.get("acpmux-find-active")?.size ??
            0) > 0,
        null,
        { timeout: 10_000 },
      );
      await page.evaluate(async () => {
        const range = [
          ...((CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights.get("acpmux-find-active") ?? []),
        ][0];
        const block = range?.startContainer.parentElement;
        if (!block) throw new Error("no current match");
        // 40 steps of 20 px over 2 s: more than the output box and the viewport.
        for (let step = 1; step <= 40; step += 1) {
          block.style.marginTop = `${step * 20}px`;
          // fixed-wait: the scenario is layout above the match that keeps moving for 2 s of wall time
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
      });
      await settleInView(page);
      expect((await state(page)).inView).toBe(true);
      await page.close();
    });
  });
});
