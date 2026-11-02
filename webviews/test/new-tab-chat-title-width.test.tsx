// l10n-allow-file: test fixtures.
// A title-only row in the New Tab's Chats list runs to the time column (Leo 2026-10-13, cosmic-gray):
// it cut "well we have cosmic-gray which is pr..." at 45% of the row with half the row empty, the cap
// meant to leave room for a preview it did not have. A row with a preview keeps its title capped.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { ChatCards } from "../src/agent-session/acpmux/newtab/ChatCards";
import type { ChatCard } from "../src/agent-session/acpmux/newtab/screenModel";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-chat-title-width.test.tsx", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-chat-title-width: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab chat title width", () => test("chromium", () => {}));
    return;
  }
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  // Longer than the 720px row at any body size, so the title-only row overflows and must run to the
  // time column rather than end where its text happens to end.
  const long =
    "well we have cosmic-gray which is probably the best box to reproduce this one on, then the rest of the fleet after that";
  const cards: ChatCard[] = [
    { sessionId: "a", title: long, harness: "claude", age: "6m", state: "idle" },
    {
      sessionId: "b",
      title: "cg-lane-adopt",
      harness: "claude",
      age: "6m",
      state: "idle",
      message: long,
    },
  ];

  test("a title-only row's title fills the row up to the time column", async () => {
    const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/newtab/screen.css"), "utf8");
    const list = renderToStaticMarkup(createElement(ChatCards, { cards, variant: "list", onOpen: () => {} }));
    const page = await browser!.newPage({ viewport: { width: 900, height: 400 } });
    await page.setContent(
      `<style>${css}</style><div style="width:720px;margin:40px;font:13px system-ui">${list}</div>`,
    );
    const rows = await page.evaluate(() =>
      [...document.querySelectorAll(".nt-card")].map((card) => {
        const box = (selector: string) => card.querySelector(selector)!.getBoundingClientRect();
        const message = card.querySelector(".nt-card-message");
        return {
          row: card.getBoundingClientRect().width,
          title: box(".nt-card-title"),
          meta: box(".nt-card-meta"),
          message: message ? message.getBoundingClientRect() : null,
        };
      }),
    );
    const [titleOnly, withPreview] = rows;
    // Up to the time column: only the row's 10px gap between them.
    expect(titleOnly!.meta.left - titleOnly!.title.right).toBeLessThanOrEqual(12);
    expect(titleOnly!.title.width).toBeGreaterThan(titleOnly!.row * 0.7);
    // A preview keeps its room: the title stays capped and the preview runs to the time column.
    expect(withPreview!.title.width).toBeLessThanOrEqual(withPreview!.row * 0.45 + 1);
    expect(withPreview!.meta.left - withPreview!.message!.right).toBeLessThanOrEqual(12);
    await page.close();
  });
});
