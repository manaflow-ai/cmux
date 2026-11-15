// cmux-web-test-timeout: 300
// l10n-allow-file: the stand-in chat's text and assertions, not shipped UI.
// A chat with a turn open and nothing arriving paints nothing on the main thread: its running marks (the
// spinners, the live line's shimmer, the worked-for time) move on the compositor, and the transcript is never
// painted again for them (cmuxterm-hq goals/chats-flat-at-any-length.md: "A chat should cost about what an empty
// chat costs while idle"). Leo's NIGHTLY, 2026-11-15, a coordinator chat with a turn running: 1.88-2.1 GB,
// 102-118 % CPU, 455-557 frames every 5 s, 0.4-1.3 s of long tasks every 5 s.
//
// The production pane (a vite build) in Chromium, the engine of the app's agent renderer, on the papercut stand-in
// daemon: a chat of TURNS finished turns and one open turn as a coordinator's stands (a reply, a plan whose step is
// in progress, two commands running). Once it settles, a CDP trace over WINDOW_S seconds of nothing
// (bench/paintWindow.ts) counts the main-thread paints, and the page lists its running animations and what each
// animates, in each working look (`data-working-look`: the spinner by default, breathe and shimmer in Debug) and with
// the composer focused (its caret).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-running-idle-paint.test.ts
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type CDPSession, type Page } from "playwright";
import { describePaintWindow, paintWindow } from "../bench/paintWindow";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-running-idle-paint.test.ts", async () => {
  setDefaultTimeout(280_000);
  const TURNS = 60;
  const WINDOW_S = 4;
  // The live line's time ("1m 4s") changes once a second, and a shimmer sweep starts every 4 s: each is a paint of
  // its own small line. Four a second leaves room for both and for a runner's late frame, and is far below the one
  // paint a frame (60 a second) of a loop the compositor does not run.
  const MAX_PAINTS_PER_S = 4;
  const update = (u: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: u },
  });
  const todo = (content: string, status: string) => ({ content, status, priority: "medium" });
  const extra: PapercutStep[] = [
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Checking the lanes." } }),
    ],
    [
      "in",
      "plan",
      update({
        sessionUpdate: "plan",
        entries: [
          todo("Read the lanes", "completed"),
          todo("Wait on the checks", "in_progress"),
          todo("Land", "pending"),
        ],
      }),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "todo-1",
        title: "TodoWrite",
        kind: "other",
        status: "in_progress",
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: "todo-1", status: "completed" }),
    ],
  ];
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  let page: Page | undefined;
  let cdp: CDPSession | undefined;
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });
  const opened = async () => {
    if (page && cdp) return { page, cdp };
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser!, {
      turns: TURNS,
      running: true,
      extra,
      ready: ".cv-worked.is-below",
      production: {},
    });
    page = await pane.open({ width: 1200, height: 800 });
    cdp = await page.context().newCDPSession(page);
    // fixed-wait: the rows' first measures and the live line's first shimmer pass are over.
    await page.waitForTimeout(1500);
    return { page, cdp };
  };

  for (const look of ["spinner", "breathe", "shimmer", "focused"] as const)
    test(`an open turn at rest (${look}): its running marks animate on the compositor and paint nothing a frame`, async () => {
      const { page, cdp } = await opened();
      await page.evaluate((look) => {
        const root = document.documentElement;
        if (look === "breathe" || look === "shimmer") root.dataset.workingLook = look;
        else delete root.dataset.workingLook;
      }, look);
      if (look === "focused")
        await page.locator(".acpmux-md [contenteditable='true'], .acpmux-md").first().click({ force: true });
      // fixed-wait: the look's loops start.
      await page.waitForTimeout(500);
      const window = await paintWindow(page, cdp, WINDOW_S);
      console.log(describePaintWindow(`running turn at rest, ${look}`, window));
      // A run on the fleet keeps a still of what the window looked at (cmux-ci test --artifact).
      if (process.env.FAST_CHECKS_OUT)
        await page
          .screenshot({ path: `${process.env.FAST_CHECKS_OUT}/running-idle-${look}.png` })
          .catch(() => undefined);
      const shown = window.animations.filter((animation) => animation.onScreen);
      expect(
        shown
          .filter((animation) => !animation.compositable)
          .map((a) => `${a.name} on ${a.target}: ${a.properties.join(", ")}`),
      ).toEqual([]);
      expect(window.paintsPerS).toBeLessThanOrEqual(MAX_PAINTS_PER_S);
    });
});
