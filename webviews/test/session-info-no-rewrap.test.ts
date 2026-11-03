// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture reply, not shipped UI.
// Leo, 2026-11-03: "on the current version the session info toggle push to the left it shifts some
// newlines/line breaks which shouldn't happen like the agent chat's horizontal width shouldn't be
// shifted its position sure but it itself and its text shouldn't be affected by the session info if it
// would need to be then session info should be an overlay". Opening and closing Session Info may move
// the transcript's column, never resize it: on every painted frame of the open and the close, at every
// stage (floating 1600px, pushing 1100px and 1420px, over the chat 740px and 1200px), each transcript
// row keeps its width and its height, and a long reply keeps its line count (SessionInfo.tsx
// pushKeepsColumn, sessionInfo.css --acpmux-session-info-column).
//
// The page is the pane's dev entry with a stand-in acpmux (support/papercutChat.ts). Real Chromium and
// WebKit (the app's engine); CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/session-info-no-rewrap.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("session-info-no-rewrap.test.ts", async () => {
  setDefaultTimeout(300_000);
  const LONG =
    "Long reply: " +
    Array.from(
      { length: 24 },
      (_, n) => `step ${n + 1} rebuilt the column, measured each wrapped line and compared it with the last frame`,
    ).join(", ") +
    ".";
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`session-info-no-rewrap: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("session info no rewrap", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, {
      turns: 2,
      running: false,
      extra: [
        ["mux", "user_message", { text: "Explain it at length" }],
        ["mux", "turn_started", {}],
        [
          "in",
          "agent_message_chunk",
          {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: LONG } },
            },
          },
        ],
        ["mux", "turn_result", { status: "completed" }],
      ],
      ready: "text=Long reply:",
    });
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// Samples every transcript row's width and height, and the long reply's line count, on each painted
  /// frame from now until `stop`; returns how far each strayed from its first reading.
  const startSampling = (page: Page) =>
    page.evaluate(() => {
      type Probe = Window & { __rewrap?: { stop: boolean; worst: Record<string, number> } };
      const probe = window as Probe;
      const lines = () => {
        const reply = [...document.querySelectorAll(".acpmux-row")].find((row) =>
          row.textContent?.includes("Long reply:"),
        );
        if (!reply) return 0;
        const range = document.createRange();
        range.selectNodeContents(reply);
        return new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top))).size;
      };
      const read = () => {
        const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => {
          const box = row.getBoundingClientRect();
          return { width: box.width, height: box.height };
        });
        return { rows, lines: lines() };
      };
      const first = read();
      const worst = { width: 0, height: 0, lines: 0, rows: first.rows.length, firstLines: first.lines };
      probe.__rewrap = { stop: false, worst };
      // Read after each painted frame (support/paintedFrames.ts), until stopSampling.
      window.cmuxAfterPaint(() => {
        if (probe.__rewrap!.stop) return false;
        const now = read();
        now.rows.forEach((row, index) => {
          const was = first.rows[index];
          if (!was) return;
          worst.width = Math.max(worst.width, Math.abs(row.width - was.width));
          worst.height = Math.max(worst.height, Math.abs(row.height - was.height));
        });
        worst.lines = Math.max(worst.lines, Math.abs(now.lines - first.lines));
        return true;
      });
    });
  const stopSampling = (page: Page) =>
    page.evaluate(() => {
      const probe = window as Window & { __rewrap?: { stop: boolean; worst: Record<string, number> } };
      probe.__rewrap!.stop = true;
      return probe.__rewrap!.worst;
    });
  const settle = (page: Page) =>
    page.evaluate(async () => {
      await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
    });

  for (const name of browsers.keys())
    for (const [width, stage] of [
      [740, "overlay"],
      [1100, "push"],
      [1200, "overlay"],
      [1420, "push"],
      [1600, "overlay"],
    ] as const)
      test(`${name}: in a ${width}px pane, opening and closing Session Info rewraps no line`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 800 });
        try {
          await page.evaluate(() =>
            (
              window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
            ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
          );
          const toggle = page.locator("button.acpmux-session-info-toggle");
          await toggle.waitFor({ timeout: 10_000 });
          const panel = page.locator("aside.acpmux-session-info");
          if ((await toggle.getAttribute("aria-pressed")) === "true") {
            await toggle.click();
            await panel.waitFor({ state: "detached", timeout: 10_000 });
          }
          await settle(page);
          await startSampling(page);
          await toggle.click();
          await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
          await settle(page);
          const placement = await panel.getAttribute("data-placement");
          await toggle.click();
          await panel.waitFor({ state: "detached", timeout: 10_000 });
          await settle(page);
          const worst = await stopSampling(page);
          expect(worst.rows).toBeGreaterThan(0);
          expect(worst.firstLines).toBeGreaterThan(2);
          // A tenth of a pixel absorbs the engine's layout units; a wrapped line is a whole line's height.
          const px = (value: number) => Math.round(value * 10) / 10;
          expect({ placement, width: px(worst.width), height: px(worst.height), lines: worst.lines }).toEqual({
            placement: stage,
            width: 0,
            height: 0,
            lines: 0,
          });
        } finally {
          await page.close();
        }
      });
});
