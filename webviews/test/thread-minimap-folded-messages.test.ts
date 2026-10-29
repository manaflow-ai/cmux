// l10n-allow-file: test fixture prompts and messages, not shipped UI.
// The thread rail (threadMinimap/ThreadMinimap.tsx) draws its ticks in a real pane, with and without
// folded received messages (Leo, 2026-10-28: "also i dont see the left scroll rail at all anymore?",
// then "also i updated htenightly a bunch... but the left scroll rail stuff still is disappeared :(").
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-folded-messages.test.ts
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, type PapercutStep } from "./support/papercutChat";

const START = Date.UTC(2026, 9, 19, 9, 0, 0) + 60_000;

/// Four messages in a row from other sessions: the transcript folds them into one card. Each still
/// opens its turn, so each keeps its tick, as it did before they folded (#26980).
const received: PapercutStep[] = [
  "The green build is up.",
  "The head is 2a7ce36.",
  "The review box says SHIP.",
  "Landing it now.",
].map((text, index) => [
  "mux",
  "user_message",
  { text, _meta: { provenance: { kind: "session_message", from: "acp:s-sr2", fromName: "claude-sr2" } } },
  START + index * 1000,
]);

await requireBrowserLane("thread-minimap-folded-messages.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers: [string, Browser][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.push([name, await engine.launch({ headless: true })]);
    } catch {
      console.warn(`thread-minimap-folded-messages: skipping ${name}`);
    }
  }
  if (!browsers.length) {
    describe.skip("rail with folded messages", () => test("browsers", () => {}));
    return;
  }
  afterAll(async () => {
    for (const [, browser] of browsers) await browser.close();
  });

  for (const [name, browser] of browsers)
    for (const [label, turns, extra, ready, expected] of [
      // Eight typed prompts: the rail shows from four (threadMinimap/model.ts MIN_PROMPTS).
      ["a plain transcript", 8, [], undefined, 8],
      // A chat that is mostly other agents' messages, like a coordinator's: two typed prompts, then
      // four received messages folded into one card. Counting only the card's row, the rail had two
      // prompts and drew nothing.
      ["folded received messages", 2, received, ".cv-waiting", 6],
    ] as [string, number, PapercutStep[], string | undefined, number][])
      test(`${name}: the rail draws its ticks for ${label}`, async () => {
        const pane = await papercutPane(() => browser, { turns, running: false, extra, ready });
        try {
          const page = await pane.open({ width: 1200, height: 800 });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(String(error)));
          const ticks = page.locator(".acpmux-minimap__tick");
          const found = await ticks
            .first()
            .waitFor({ timeout: 10_000 })
            .then(() => true)
            .catch(() => false);
          const state = await page.evaluate(() => ({
            rail: !!document.querySelector(".acpmux-minimap"),
            ticks: document.querySelectorAll(".acpmux-minimap__tick").length,
            folds: document.querySelectorAll(".cv-waiting").length,
            scroller: document.querySelector(".acpmux-scroll")?.getBoundingClientRect().width ?? -1,
          }));
          console.log(`thread-minimap-folded-messages ${name} ${label}: ${JSON.stringify({ ...state, errors })}`);
          if (extra.length) expect(state.folds).toBe(1);
          expect(found, "the rail draws ticks").toBe(true);
          expect(state.ticks).toBe(expected);
          expect(errors).toEqual([]);
          await page.close();
        } finally {
          await pane.close();
        }
      });
});
