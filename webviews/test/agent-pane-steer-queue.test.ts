// cmux-web-test-timeout: 240
// l10n-allow-file: the mock daemon's fixture chats and a typed steer, not shipped UI.
// Steer queue (steerQueue/, experiment `steer-queue`) in the real pane: `?mock` is the real direct
// client against the in-page mock daemon, whose seeded chats wait on the person (Review the
// terminal tab strip), run quietly (Fix sidebar flicker) and finished unread (Localize the changes
// view).
//
// - Off by default: ⌘⇧J opens nothing.
// - ⌘⇧J opens the queue over the chat, ranked: the ask first, the quiet turn, then the unread finish.
// - Typing a line on the quiet turn and pressing Return opens that chat under the queue, the line
//   lands in its transcript, the step is in the person's record (log.ts), and the focus moves on.
// - ⌘. stops the quiet turn: acpmux ends it and it no longer runs in the queue.
// - A line typed on a chat that asks goes on in its composer when Return opens it.
// - Escape clears a typed line first, then closes the queue.
//
// It writes stills of each step to $FAST_CHECKS_OUT when CI gives one (the PR's capture).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-steer-queue.test.ts", async () => {
  setDefaultTimeout(220_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // The mock pane draws the host's theme, whatever the media's colour scheme: one still per step.
  const still = async (page: Page, name: string) => {
    if (!out) return;
    await page.screenshot({ path: path.join(out, `steer-queue-${name}.png`) });
  };
  const rows = (page: Page) =>
    page.$$eval(".acpmux-steer-row", (items) =>
      items.map((item) => ({
        name: item.querySelector(".acpmux-steer-name")?.textContent ?? "",
        reason: item.getAttribute("data-reason"),
        selected: item.getAttribute("aria-selected") === "true",
        said: item.querySelector(".acpmux-steer-said")?.textContent ?? "",
      })),
    );

  const open = async (on: boolean) => {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 720 } });
    await page.addInitScript(
      (arm) => {
        localStorage.setItem("cmux.experiments", JSON.stringify({ "steer-queue": arm }));
        localStorage.removeItem("cmux.steerQueue.log");
      },
      on ? "on" : "off",
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForSelector("form.acpmux-composer", { timeout: 60_000 });
    return page;
  };

  test("off by default: ⌘⇧J opens nothing", async () => {
    const page = await open(false);
    await page.keyboard.press("Meta+Shift+J");
    // The key's handler runs in the same task as the press; two frames let any render it caused land.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    expect(await page.$(".acpmux-steer-queue")).toBeNull();
    await page.close();
  });

  const QUIET = "Fix sidebar flicker on theme change";
  const openQueue = async (page: Page) => {
    await page.keyboard.press("Meta+Shift+J");
    await page.waitForSelector(".acpmux-steer-queue");
    return rows(page);
  };
  const rowState = (page: Page, title: string) =>
    page.evaluate((name) => {
      const row = [...document.querySelectorAll(".acpmux-steer-row")].find(
        (item) => item.querySelector(".acpmux-steer-name")?.textContent === name,
      );
      return row ? { reason: row.getAttribute("data-reason"), step: row.getAttribute("data-step") } : undefined;
    }, title);

  test("ranked by reason: asks, failures, quiet turns, unread finishes, then running", async () => {
    const page = await open(true);
    const ranked = await openQueue(page);
    console.log(`STEER-QUEUE-RANKED ${JSON.stringify(ranked)}`);
    const order = ranked.map((row) => row.name);
    const ask = order.indexOf("Review the terminal tab strip");
    const quiet = order.indexOf(QUIET);
    const unread = order.indexOf("Localize the changes view");
    // The mock seeds more chats than these three; every row ranks by its reason, in this order.
    const RANK = ["ask", "failed", "stalled", "review", "running"];
    const ranks = ranked.map((row) => RANK.indexOf(row.reason ?? ""));
    expect(ranks.every((rank) => rank >= 0)).toBe(true);
    expect(ranks).toEqual([...ranks].sort((a, b) => a - b));
    expect(ask).toBeGreaterThanOrEqual(0);
    expect(ranked[quiet]?.reason).toMatch(/^(stalled|running)$/);
    expect(quiet).toBeGreaterThan(ask);
    expect(unread).toBeGreaterThan(quiet);
    expect(ranked[0]?.selected).toBe(true);
    await still(page, "open");
    await page.close();
  });

  test("a typed line steers the quiet turn: it lands in that chat and the focus moves on", async () => {
    const page = await open(true);
    const ranked = await openQueue(page);
    const quiet = ranked.findIndex((row) => row.name === QUIET);
    await page.keyboard.press(`${quiet + 1}`);
    expect((await rows(page))[quiet]?.selected).toBe(true);
    const line = "Check every theme in dark mode before the PR";
    await page.keyboard.type(line);
    await still(page, "typed");
    await page.keyboard.press("Enter");
    // The chat under the queue is the steered one, and the line is in its transcript.
    await page.waitForFunction((text) => document.querySelector(".acpmux-thread")?.textContent?.includes(text), line, {
      timeout: 30_000,
    });
    const log = await page.evaluate(() => JSON.parse(localStorage.getItem("cmux.steerQueue.log") ?? "[]"));
    console.log(`STEER-QUEUE-LOG ${JSON.stringify(log)}`);
    expect(log).toHaveLength(1);
    expect(log[0]).toMatchObject({ act: "steer", text: line });
    expect(await page.$eval(".acpmux-steer-field", (field) => (field as HTMLInputElement).value)).toBe("");
    // A line typed while the next step is on its way stays in the field once that step lands.
    const slow = "Then rebase on the base";
    const finished = (await rows(page)).findIndex((row) => row.reason === "review");
    expect(finished).toBeGreaterThanOrEqual(0);
    await page.keyboard.press(`${finished + 1}`);
    await page.keyboard.type(slow);
    await page.evaluate(() => {
      (globalThis as { cmuxAcpmuxMockSlowMethod?: string; cmuxAcpmuxMockSlowMs?: number }).cmuxAcpmuxMockSlowMethod =
        "session/prompt";
      (globalThis as { cmuxAcpmuxMockSlowMs?: number }).cmuxAcpmuxMockSlowMs = 1_500;
    });
    await page.keyboard.press("Enter");
    await page.keyboard.type(" and push");
    await page.waitForFunction((text) => document.querySelector(".acpmux-thread")?.textContent?.includes(text), slow, {
      timeout: 30_000,
    });
    await page.waitForFunction(
      () => JSON.parse(localStorage.getItem("cmux.steerQueue.log") ?? "[]").length === 2,
      null,
      { timeout: 30_000 },
    );
    expect(await page.$eval(".acpmux-steer-field", (field) => (field as HTMLInputElement).value)).toBe("and push");
    await page.evaluate(() => {
      delete (globalThis as { cmuxAcpmuxMockSlowMethod?: string }).cmuxAcpmuxMockSlowMethod;
    });
    await page.keyboard.press("Escape");
    // While its row lists, it says what the person did, and the focus has moved on from it.
    const after = await rows(page);
    console.log(`STEER-QUEUE-STEERED ${JSON.stringify(after)}`);
    const steered = after.find((row) => row.name === QUIET);
    if (steered) {
      expect(steered.said.startsWith("Sent")).toBe(true);
      expect(steered.selected).toBe(false);
    }
    await still(page, "steered");
    await page.close();
  });

  test("⌘. stops the quiet turn: acpmux ends it and it no longer runs in the queue", async () => {
    const page = await open(true);
    const ranked = await openQueue(page);
    const quiet = ranked.findIndex((row) => row.name === QUIET);
    await page.keyboard.press(`${quiet + 1}`);
    await page.keyboard.press("Meta+.");
    await page.waitForFunction(
      (name) =>
        ![...document.querySelectorAll(".acpmux-steer-row")].some(
          (row) =>
            row.querySelector(".acpmux-steer-name")?.textContent === name &&
            ["running", "stalled"].includes(row.getAttribute("data-reason") ?? ""),
        ),
      QUIET,
      { timeout: 30_000 },
    );
    console.log(`STEER-QUEUE-STOPPED ${JSON.stringify(await rowState(page, QUIET))}`);
    const log = await page.evaluate(() => JSON.parse(localStorage.getItem("cmux.steerQueue.log") ?? "[]"));
    expect(log[0]).toMatchObject({ act: "stop" });
    await still(page, "stopped");
    await page.close();
  });

  test("a line typed on a chat that asks goes on in its composer when Return opens it", async () => {
    const page = await open(true);
    const ranked = await openQueue(page);
    expect(ranked[0]?.reason).toBe("ask");
    const line = "Keep the strip as it is";
    await page.keyboard.type(line);
    await page.keyboard.press("Enter");
    await page.waitForSelector(".acpmux-steer-queue", { state: "detached" });
    await page.waitForFunction(
      (text) => document.querySelector(".acpmux-composer-prompt [contenteditable='true']")?.textContent?.includes(text),
      line,
      { timeout: 30_000 },
    );
    await page.close();
  });

  test("a press on the panel keeps the keyboard; Escape clears the line, then closes", async () => {
    const page = await open(true);
    await openQueue(page);
    // A press on the panel's chrome keeps the keyboard in the field, never on the chat under it.
    await page.click(".acpmux-steer-head");
    await page.keyboard.type("half a thought");
    expect(await page.$eval(".acpmux-steer-field", (field) => (field as HTMLInputElement).value)).toBe(
      "half a thought",
    );
    await page.keyboard.press("Escape");
    expect(await page.$eval(".acpmux-steer-field", (field) => (field as HTMLInputElement).value)).toBe("");
    await page.keyboard.press("Escape");
    await page.waitForSelector(".acpmux-steer-queue", { state: "detached" });
    await page.close();
  });
});
