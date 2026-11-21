// The background picker for VoiceOver: a tile's accessible name was only its title, while the
// ▶ badge (a moving wallpaper) was hidden and "Download in System Settings" was only a tooltip.
// A tile now describes both, so a screen reader hears what the eye sees.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const described = (tile: HTMLElement) =>
  (tile.getAttribute("aria-describedby") ?? "")
    .split(" ")
    .filter(Boolean)
    .map((id) => tile.ownerDocument.getElementById(id)?.textContent ?? "")
    .join(" ");

test("a moving wallpaper's tile says it is a video; a still one says nothing extra", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const video = page.container.querySelector<HTMLButtonElement>('[aria-label="Sonoma Graphic"]')!;
  expect(described(video)).toBe("Video");
  const still = page.container.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!;
  expect(described(still)).toBe("");
  // The descriptions are not text of their own in the card's reading order.
  const ids = (video.getAttribute("aria-describedby") ?? "").split(" ").filter(Boolean);
  expect(ids.every((id) => (document.getElementById(id) as HTMLElement).hidden)).toBe(true);
  page.unmount();
});

test("a wallpaper macOS has not downloaded says where a click takes you", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: [
        ...(page.provider.host.backdrops ?? []),
        {
          id: "system:/S/Grid Green.madesktop",
          title: "Grid Green",
          attribution: "",
          collection: "apple",
          collection_title: "Apple Wallpapers",
          downloaded: false,
        },
      ],
    }),
  );
  await settle();
  const pending = page.container.querySelector<HTMLButtonElement>('[aria-label="Grid Green"]')!;
  expect(described(pending)).toBe("Download in System Settings");
  page.unmount();
});
