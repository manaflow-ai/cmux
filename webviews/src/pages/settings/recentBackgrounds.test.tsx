// The Background card's Recent strip (Leo, 2026-11-22: "it was cumbersome back then to switch
// back"): appearance.backgroundRecents drawn newest first, a folder as a folder tile, one click
// writes appearance.background.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { recentKind, recentTiles, recentWrites } from "./recentBackgrounds";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const words = { shuffle: "Shuffle", none: "None", appearance: "Light & Dark", schedule: "Time of Day" };

test("tiles leave out the current background, junk and repeats, and name each kind", () => {
  const tiles = recentTiles(
    [
      "folder:/Users/me/Walls",
      "starryNight",
      3,
      "daily",
      "folder:/Users/me/Walls",
      "file:/a/Harbor.png",
      "appearance",
      "none",
    ],
    "starryNight",
    [{ id: "file:/a/Harbor.png", title: "Harbor" }],
    words,
  );
  expect(tiles).toEqual([
    { id: "folder:/Users/me/Walls", kind: "folder", title: "Walls" },
    { id: "daily", kind: "shuffle", title: "Shuffle" },
    { id: "file:/a/Harbor.png", kind: "picture", title: "Harbor" },
    { id: "appearance", kind: "mode", title: "Light & Dark" },
    { id: "none", kind: "none", title: "None" },
  ]);
  expect(recentTiles(null, "none", [], words)).toEqual([]);
  expect(recentTiles({ a: 1 }, "none", [], words)).toEqual([]);
  expect(recentTiles(["file:/b/Night.jpg"], "none", [], words)[0]!.title).toBe("Night.jpg");
  expect(recentKind("system:/S/Sonoma.madesktop")).toBe("picture");
  expect(recentKind("schedule")).toBe("mode");
});

async function card(values: Record<string, unknown>) {
  const page = await renderPage({ path: "/settings/appearance", mock: { values } });
  await settle();
  return { page, card: page.container.querySelector<HTMLElement>('[data-card="backdrop"]')! };
}

test("the strip is drawn above the picker and one click goes back to a rotating folder", async () => {
  const { page, card: backdrop } = await card({
    "appearance.background": "starryNight",
    "appearance.backgroundRecents": ["folder:/Users/me/Walls", "daily"],
  });
  const strip = backdrop.querySelector<HTMLElement>(".backdrop-recent")!;
  expect(strip).not.toBeNull();
  // Before the first tile row.
  expect(strip.compareDocumentPosition(backdrop.querySelector(".backdrop-grid:not(.backdrop-recent-grid)")!)).toBe(
    Node.DOCUMENT_POSITION_FOLLOWING,
  );
  const tiles = [...strip.querySelectorAll<HTMLButtonElement>("button")];
  expect(tiles.map((tile) => tile.getAttribute("aria-label"))).toEqual(["Walls", "Shuffle Paintings"]);
  expect(tiles[0]!.dataset.recentKind).toBe("folder");
  await act(async () => tiles[0]!.click());
  await settle();
  const sets = page.provider.log
    .filter((entry) => entry.op === "cmux.settings.set")
    .map((entry) => entry.params as { key?: string; value?: unknown })
    .filter((params) => params.key === "appearance.background");
  expect(sets.at(-1)).toMatchObject({ key: "appearance.background", value: "folder:/Users/me/Walls" });
  page.unmount();
});

test("with no recents there is no strip", async () => {
  const { page, card: backdrop } = await card({ "appearance.background": "starryNight" });
  expect(backdrop.querySelector(".backdrop-recent")).toBeNull();
  page.unmount();
});

test("a recent pick turns sun mode off with it, as Switch Automatically's Off does", () => {
  expect(recentWrites("folder:/Users/me/Walls", "time")).toEqual([
    ["appearance.background", "folder:/Users/me/Walls"],
    ["appearance.backgroundDynamic", null],
  ]);
  expect(recentWrites("starryNight", "appearance")).toEqual([["appearance.background", "starryNight"]]);
});
