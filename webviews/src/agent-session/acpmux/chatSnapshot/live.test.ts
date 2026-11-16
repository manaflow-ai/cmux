// The chat's copy is written again after a resize that changed no markup: a copy is drawn only at
// the size it was written at (shared.ts `fitsDocument`), so a pane resized after the last write left
// a copy the next launch refused, and the chat opened from nothing (relaunch-shift bench, "size
// 868x712, drawn at 528x512"; Leo, 2026-11-14: "too much render shift when the thing restarts").
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { noteChatTheme, watchChatSnapshot } from "./live";

const elapse = (ms: number) =>
  // fixed-wait: the copy's quiet period, write gap and resize rest are the behavior under test (live.ts times them with real timers).
  new Promise((resolve) => setTimeout(resolve, ms));

test("a resize with no markup change writes the copy again once it rests, inside the write gap", async () => {
  const dom = new JSDOM(`<!doctype html><html><body><main id="root"><p>row</p></main></body></html>`, {
    pretendToBeVisual: true,
  });
  const view = dom.window as unknown as Window & typeof globalThis;
  noteChatTheme("theme-1");
  const writes: number[] = [];
  const stop = watchChatSnapshot("s1", async () => writes.push(performance.now()), view.document);
  // The first write, once the page has been quiet.
  await elapse(1_700);
  expect(writes.length).toBe(1);
  // Nothing changed: no write past the gap.
  await elapse(200);
  expect(writes.length).toBe(1);
  // A drag's resizes: one write, once they rest, though the write gap (10 s) has not passed.
  view.dispatchEvent(new view.Event("resize"));
  await elapse(100);
  view.dispatchEvent(new view.Event("resize"));
  await elapse(200);
  expect(writes.length).toBe(1);
  await elapse(400);
  expect(writes.length).toBe(2);
  stop();
  view.dispatchEvent(new view.Event("resize"));
  await elapse(1_700);
  expect(writes.length).toBe(2);
  dom.window.close();
}, 10_000);
