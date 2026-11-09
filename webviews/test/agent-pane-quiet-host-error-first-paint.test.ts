// Leo, 2026-11-09, after a restart to update: "the chat loading kinda flickered in and out and
// layout shifted... our first loads aren't perfected yet? at least after restart?" After an update
// the app hands acpmux off, so a chat page's first handshakes fail while acpmux comes back
// (hostRetry.ts `hostIsReconnecting`), and the page says nothing about them until
// HOST_ERROR_DEADLINE_MS. Such a quiet failure drew only an empty transcript; counted as what the
// page is, it took the chat's copy and the host's picture off for that empty pane, and the rows
// came back when acpmux answered. These hold the page to:
//   - a quiet failure is not a first paint: the copy and the picture stay;
//   - a failure the page says is one (a refusal at once, a recovery past its deadline);
//   - a read chat and a New Tab page still are.
import { expect, test } from "bun:test";
import { pageShowsWhatItIs, type FirstPaintState } from "../src/agent-session/acpmux/firstPaint";

const waiting: FirstPaintState = {
  handshaken: false,
  chatDrawn: false,
  hostError: false,
  hostErrorSaid: false,
  newTab: false,
};

test("a handshake still failing quietly while acpmux restarts is no first paint", () => {
  expect(pageShowsWhatItIs({ ...waiting, hostError: true })).toBe(false);
});

test("a failure the page says is its first paint", () => {
  expect(pageShowsWhatItIs({ ...waiting, hostError: true, hostErrorSaid: true })).toBe(true);
});

test("a read chat and a New Tab page are first paints; a chat not read yet is not", () => {
  expect(pageShowsWhatItIs({ ...waiting, handshaken: true, chatDrawn: true })).toBe(true);
  expect(pageShowsWhatItIs({ ...waiting, newTab: true })).toBe(true);
  expect(pageShowsWhatItIs({ ...waiting, handshaken: true })).toBe(false);
  expect(pageShowsWhatItIs(waiting)).toBe(false);
});
