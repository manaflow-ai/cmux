// The background picker from the keyboard: Tab through its tiles previews only the one you rest
// on, after the same dwell the pointer gets, so stepping across the grid never repaints every
// window and fetches full-size art at each tile.
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const runs = (page: Awaited<ReturnType<typeof renderPage>>, op: string) =>
  page.provider.log.filter((entry) => entry.op === op).map((entry) => entry.params);

/// The page's timers on a fake clock: the dwell is the behavior, so it never rides the wall clock.
const wait = (ms: number) => void jest.advanceTimersByTime(ms);
/// The mock transport's microtask chain, drained without a timer (the fake clock holds those).
const drain = () => act(async () => {});

test("tabbing across the tiles previews only the tile you rest on", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const tiles = [
    ...page.container.querySelectorAll<HTMLButtonElement>(
      '[data-card="backdrop"] .backdrop-tile[aria-pressed]:not(.backdrop-pending)',
    ),
  ];
  expect(tiles.length).toBeGreaterThanOrEqual(3);
  // Step across three tiles faster than the dwell.
  jest.useFakeTimers();
  try {
    await act(async () => {
      for (const tile of tiles.slice(0, 3)) {
        tile.focus();
        wait(20);
      }
    });
    // The same drain that shows the rest's preview below shows none here.
    await drain();
    expect(runs(page, "cmux.settings.preview").length).toBe(0);
    // Rest on the third: it previews, once.
    await act(async () => wait(250));
    await drain();
    expect(runs(page, "cmux.settings.preview").length).toBe(1);
  } finally {
    jest.useRealTimers();
  }
  await settle();
  const previews = runs(page, "cmux.settings.preview");
  expect(previews.length).toBe(1);
  // The tile you stopped on (its thumbnail names its id), not one you passed.
  const thumb = tiles[2]!.querySelector("img")!.getAttribute("src")!;
  const rested = decodeURIComponent(decodeURIComponent(thumb.slice("backdrop/".length)));
  expect(previews[0]).toMatchObject({ key: "appearance.background", value: rested });
  page.unmount();
});
