// R82 commit 4: the Swift window's last cards are drawn by the page (the Theme section has its own
// test, themeStudio.test.tsx). The background picker (Change Background…, cx-t2x.4) previews and
// writes appearance.background on Appearance, Terminal shows the Ghostty facts,
// and Advanced shows the settings file and every problem of the last load.
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

/// Runs `act` with `ms` of the page's timers passing on a fake clock: the dwell is the behavior.
async function elapse(ms: number, run: () => void) {
  jest.useFakeTimers();
  try {
    await act(async () => {
      run();
      jest.advanceTimersByTime(ms);
    });
  } finally {
    jest.useRealTimers();
  }
}

const runs = (page: Awaited<ReturnType<typeof renderPage>>, op: string) =>
  page.provider.log.filter((entry) => entry.op === op).map((entry) => entry.params);

test("Change Background… shows the picker on Appearance: resting previews, leaving restores, a click keeps", async () => {
  const page = await renderPage({
    path: "/settings/appearance?focus=appearance.background",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  expect(picker.querySelector("img")!.getAttribute("src")).toBe("backdrop/starryNight");
  // Its Opacity slider is in the picker, and the two rows are not repeated in Window Background.
  expect(picker.querySelector('[data-row-key="appearance.backgroundOpacity"]')).not.toBeNull();
  expect(page.container.querySelectorAll('[data-row-key="appearance.backgroundOpacity"]').length).toBe(1);
  // The picker is not a row: the row keys (↑/↓) step from the search field to its Opacity row.
  expect(page.container.querySelector('[data-row-key="appearance.background"]')).toBeNull();
  // Change Background… lands on the saved choice, not on the slider.
  expect(document.activeElement?.getAttribute("aria-label")).toBe("The Starry Night");

  const tile = picker.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!;
  await elapse(200, () => tile.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true })));
  await settle();
  expect(runs(page, "cmux.settings.preview").at(-1)).toMatchObject({
    key: "appearance.background",
    value: "starryNight",
  });
  expect(runs(page, "cmux.settings.set").length).toBe(0);
  await act(async () => tile.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true })));
  await settle();
  expect(runs(page, "cmux.settings.preview.end").at(-1)).toMatchObject({ key: "appearance.background" });

  await act(async () => tile.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({ key: "appearance.background", value: "starryNight" });
  page.unmount();
});

test("Apple Wallpapers: tiles show only their names; one not downloaded opens the Wallpaper pane", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const apple = { collection: "apple", collection_title: "Apple Wallpapers" };
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: [
        ...(page.provider.host.backdrops ?? []),
        {
          id: "system:/S/Sonoma.heic",
          title: "Sonoma",
          attribution: "macOS system wallpaper · Sonoma",
          ...apple,
          downloaded: true,
        },
        { id: "system:/S/Grid Green.madesktop", title: "Grid Green", attribution: "", ...apple, downloaded: false },
      ],
    }),
  );
  await settle();
  const group = page.container.querySelector<HTMLElement>('[data-collection="apple"]')!;
  expect(group.querySelector(".backdrop-group-title")!.textContent).toBe("Apple Wallpapers");
  const tiles = [...group.querySelectorAll<HTMLButtonElement>(".backdrop-grid > button")];
  expect(tiles.map((tile) => tile.textContent)).toEqual(["Sonoma", "Grid Green"]);
  const [sonoma, grid] = tiles;
  expect(sonoma.title).toBe("");
  expect(sonoma.querySelector("svg.backdrop-download")).toBeNull();
  // Not downloaded: dimmed, a cloud in the corner, and the Wallpaper pane on click.
  expect(grid.title).toBe("Download in System Settings");
  expect(grid.classList.contains("backdrop-pending")).toBe(true);
  expect(grid.querySelector("svg.backdrop-download")).not.toBeNull();
  await act(async () => grid.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.wallpaper_settings").length).toBe(1);
  expect(runs(page, "cmux.settings.set").length).toBe(0);
  // Downloaded in System Settings meanwhile (macOS sends nothing): back in cmux, the tile is ready.
  page.provider.host = {
    ...page.provider.host,
    backdrops: page.provider.host.backdrops!.map((row) => ({ ...row, downloaded: true })),
  };
  await act(async () => window.dispatchEvent(new Event("focus")));
  await settle();
  expect(group.querySelector('[title="Download in System Settings"]')).toBeNull();
  expect(group.querySelectorAll(".backdrop-pending").length).toBe(0);
  await act(async () => sonoma.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({
    key: "appearance.background",
    value: "system:/S/Sonoma.heic",
  });
  page.unmount();
});

test("a wallpaper whose id is a file path gets its thumbnail: the id reaches the app as one segment", async () => {
  const page = await renderPage({ path: "/settings/appearance?focus=appearance.background" });
  const id = "system:/System/Library/Desktop Pictures/.wallpapers/Sonoma/Sonoma Graphic Light Landscape.mov";
  const tile = page.container.querySelector<HTMLButtonElement>('[aria-label="Sonoma Graphic"]')!;
  const src = tile.querySelector("img")!.getAttribute("src")!;
  // The app's page scheme reads the decoded URL path and splits it on "/" (PageSchemeHandler.route),
  // then the thumbnail source decodes its one segment (SettingsBackdropThumbnails).
  const segments = decodeURIComponent(new URL(src, "cmux-page://cmux.settings/").pathname).split("/").filter(Boolean);
  expect(segments.length).toBe(2);
  expect(segments[0]).toBe("backdrop");
  expect(decodeURIComponent(segments[1]!)).toBe(id);
});

test("Shuffle Paintings is a tile that keeps appearance.background daily", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const tile = page.container.querySelector<HTMLButtonElement>(
    '[data-card="backdrop"] [aria-label="Shuffle Paintings"]',
  )!;
  expect(tile).not.toBeNull();
  await act(async () => tile.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({ key: "appearance.background", value: "daily" });
  page.unmount();
});

test("Change Background… on a workspace chooses that workspace's own background", async () => {
  const page = await renderPage({
    path: "/settings/appearance?focus=appearance.background&workspace=ws-1",
    mock: {
      values: { "appearance.background": "starryNight" },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: null }],
    },
  });
  await settle();
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  // It opens on All Workspaces, so Change Background… still chooses for every window.
  expect(picker.querySelector<HTMLInputElement>('[aria-label="All Workspaces"]')!.checked).toBe(true);
  expect(picker.querySelector('[aria-label="Same as All Workspaces"]')).toBeNull();
  const scope = picker.querySelector<HTMLInputElement>('[aria-label="This Workspace (Research)"]')!;
  await act(async () => scope.click());
  await settle();
  expect(scope.checked).toBe(true);
  // It follows All Workspaces until it has its own; the app-wide image tiles are left out.
  const follow = picker.querySelector<HTMLButtonElement>('[aria-label="Same as All Workspaces"]')!;
  expect(follow.getAttribute("aria-pressed")).toBe("true");
  expect(picker.textContent).not.toContain("Choose Image");
  // Material is the window's, not the workspace's: it stays in the card on This Workspace too.
  expect(picker.querySelector('[data-row-key="appearance.backgroundBlur"]')).not.toBeNull();

  const none = picker.querySelector<HTMLButtonElement>('[aria-label="No wallpaper"]')!;
  const appPreviews = runs(page, "cmux.settings.preview").length;
  await elapse(200, () => none.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true })));
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.preview").at(-1)).toMatchObject({
    workspace: "ws-1",
    value: "none",
  });
  expect(runs(page, "cmux.settings.preview").length).toBe(appPreviews);
  await act(async () => none.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true })));
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.preview").at(-1)).toMatchObject({ workspace: "ws-1", end: true });

  await act(async () => none.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.set").at(-1)).toMatchObject({ workspace: "ws-1", value: "none" });
  expect(runs(page, "cmux.settings.set").length).toBe(0);
  expect(none.getAttribute("aria-pressed")).toBe("true");
  await act(async () => follow.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.set").at(-1)).toMatchObject({ workspace: "ws-1", value: null });

  // All Workspaces chooses appearance.background again.
  const all = picker.querySelector<HTMLInputElement>('[aria-label="All Workspaces"]')!;
  await act(async () => all.click());
  await settle();
  expect(picker.querySelector('[aria-label="Same as All Workspaces"]')).toBeNull();
  await act(async () => picker.querySelector<HTMLButtonElement>('[aria-label="No wallpaper"]')!.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({ key: "appearance.background", value: "none" });
  page.unmount();
});

test("This Workspace's Opacity previews while the slider moves, saves on release, and clears", async () => {
  const page = await renderPage({
    path: "/settings/appearance?workspace=ws-1",
    mock: { workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: "starryNight", opacity: null }] },
  });
  await settle();
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  // All Workspaces shows the app's Opacity row; This Workspace its own tint over art instead.
  expect(picker.querySelector('[data-row-key="appearance.backgroundOpacity"]')).not.toBeNull();
  await act(async () => picker.querySelector<HTMLInputElement>('[aria-label="This Workspace (Research)"]')!.click());
  await settle();
  expect(picker.querySelector('[data-row-key="appearance.backgroundOpacity"]')).toBeNull();
  const row = picker.querySelector<HTMLElement>("[data-workspace-opacity]")!;
  expect(row.textContent).toContain("Follows All Workspaces");
  const slider = row.querySelector<HTMLInputElement>('input[type="range"]')!;
  await act(async () => {
    slider.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true }));
    const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    set.call(slider, "0.8");
    slider.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.preview").at(-1)).toMatchObject({
    workspace: "ws-1",
    opacity: 0.8,
  });
  expect(runs(page, "cmux.settings.backdrop.workspace.set").length).toBe(0);
  await act(async () => slider.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true })));
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.set").at(-1)).toMatchObject({ workspace: "ws-1", opacity: 0.8 });
  expect(runs(page, "cmux.settings.backdrop.workspace.preview").at(-1)).toMatchObject({ workspace: "ws-1", end: true });
  expect(runs(page, "cmux.settings.set").length).toBe(0);

  const reset = [...row.querySelectorAll("button")].find((button) => button.textContent === "Use All Workspaces")!;
  await act(async () => reset.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.set").at(-1)).toMatchObject({ workspace: "ws-1", opacity: null });
  expect(row.textContent).toContain("Follows All Workspaces");
  page.unmount();
});

// Leo, 10-19: "the opacity thing, and then the window glass, it just doesn't make sense". The
// wallpaper card holds the window's two controls, Opacity and Material, once each. The Window Glass
// switch (Material = Clear Glass under another name), the legacy Backdrop Art chooser and the
// experimental Glass Transparency slider (a second opacity) are gone from the page; their keys
// still load.
test("the wallpaper card holds Opacity and Material once each, and nothing repeats them", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const card = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  expect(card.querySelector("[data-window-glass]")).toBeNull();
  const material = card.querySelector<HTMLElement>('[data-row-key="appearance.backgroundBlur"]');
  expect(material).not.toBeNull();
  expect(card.querySelector('[data-row-key="appearance.backgroundOpacity"]')).not.toBeNull();
  for (const key of ["appearance.backgroundBlur", "appearance.backgroundOpacity"]) {
    expect(page.container.querySelectorAll(`[data-row-key="${key}"]`).length).toBe(1);
  }
  expect(page.container.querySelector('[data-row-key="appearance.backdropArt"]')).toBeNull();
  page.unmount();
  const labs = await renderPage({
    path: "/settings/experimental",
    mock: { values: { "appearance.experimentalControls": true } },
  });
  expect(labs.container.querySelector('[data-row-key="appearance.glassTransparency"]')).toBeNull();
  expect(labs.container.querySelector('[data-row-key="appearance.hue"]')).not.toBeNull();
  labs.unmount();
});

test("sweeping the pointer across the picker previews nothing", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const tile = page.container.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!;
  await elapse(200, () => {
    tile.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
    tile.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true }));
  });
  await settle();
  expect(runs(page, "cmux.settings.preview").length).toBe(0);
  page.unmount();
});

test("Terminal shows the Ghostty facts; Advanced shows the file and every problem", async () => {
  const terminal = await renderPage({ path: "/settings/terminal" });
  expect(terminal.container.textContent).toContain("~/.config/ghostty/config");
  terminal.unmount();
  const page = await renderPage({
    path: "/settings/advanced",
    mock: { diagnostics: [{ path: "nope.key", message: "unknown key" }] },
  });
  expect(page.container.textContent).toContain("/Users/me/.config/cmux/cmux-next.json");
  expect(page.container.querySelector("[data-problem]")!.textContent).toContain("unknown key");
  const reveal = [...page.container.querySelectorAll<HTMLButtonElement>("button")].find(
    (b) => b.textContent === "Show in Finder",
  )!;
  await act(async () => reveal.click());
  await settle();
  expect(runs(page, "cmux.settings.file.reveal").length).toBe(1);
  page.unmount();
});

test("Advanced names the loaded settings file and shows one Reload Configuration", async () => {
  const page = await renderPage({
    path: "/settings/advanced",
    mock: {
      settingsFile: "/Users/me/.config/cmux/cmux.json",
      diagnostics: [{ path: "nope.key", message: "unknown key" }],
    },
  });
  const text = page.container.textContent ?? "";
  expect(page.container.querySelector('[data-card="problems"] .group-title')!.textContent).toBe(
    "Problems in cmux.json",
  );
  const buttons = [...page.container.querySelectorAll<HTMLButtonElement>("button")].map((b) => b.textContent);
  expect(buttons.filter((title) => title === "Open cmux.json").length).toBe(1);
  expect(buttons.filter((title) => title === "Reload Configuration").length).toBe(1);
  expect(text).toContain("Resets everything in cmux.json. Custom actions stay.");
  expect(text).not.toContain("cmux-next.json");
  page.unmount();
});

test("an aerial macOS has not downloaded shows as a cloud tile that opens the Wallpaper pane", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const moving = { collection: "video", collection_title: "Moving wallpapers", video: true };
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: [
        ...(page.provider.host.backdrops ?? []),
        { id: "system:/aerials/4KSDR240FPS/A1.mov", title: "Tahoe Morning", attribution: "", ...moving },
        {
          id: "system:/aerials/4KSDR240FPS/B2.mov",
          title: "Iceland Dusk",
          attribution: "",
          ...moving,
          downloaded: false,
        },
      ],
    }),
  );
  await settle();
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  const ready = picker.querySelector<HTMLButtonElement>('[aria-label="Tahoe Morning"]')!;
  const pending = picker.querySelector<HTMLButtonElement>('[aria-label="Iceland Dusk"]')!;
  expect(ready.classList.contains("backdrop-pending")).toBe(false);
  expect(ready.querySelector("img")).not.toBeNull();
  // No thumbnail to fetch for a movie that is not on disk: an empty tile with a cloud.
  expect(pending.classList.contains("backdrop-pending")).toBe(true);
  expect(pending.querySelector("img")).toBeNull();
  expect(pending.querySelector("svg.backdrop-download")).not.toBeNull();
  await act(async () => pending.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.wallpaper_settings").length).toBe(1);
  expect(
    runs(page, "cmux.settings.set").filter((p) => (p as { key: string }).key === "appearance.background").length,
  ).toBe(0);
  page.unmount();
});

test("Add from a Link downloads an image and sets it; a refused link says why; your images can be removed", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const picker = () => page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  const linkTile = [...picker().querySelectorAll<HTMLButtonElement>("button.backdrop-tile")].find((button) =>
    button.textContent?.includes("Add from a Link"),
  )!;
  await act(async () => linkTile.click());
  await settle();
  const form = () => page.container.querySelector<HTMLElement>('[data-card="backdrop-link"]');
  const field = form()!.querySelector<HTMLInputElement>('input[type="url"]')!;
  const type = async (text: string) => {
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(field, text);
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
  };
  const submit = async () => {
    await act(async () => form()!.querySelector<HTMLButtonElement>('button[type="submit"]')!.click());
    await settle();
  };

  await type("http://example.com/sea.jpg");
  await submit();
  expect(form()!.querySelector("output")!.textContent).toBe("Use a link that starts with https://.");
  await type("https://example.com/notes.txt");
  await submit();
  expect(form()!.querySelector("output")!.textContent).toBe("That is not an image or a video this Mac can play.");

  await type("https://example.com/sea.jpg");
  await submit();
  expect(runs(page, "cmux.settings.backdrop.image.link").at(-1)).toMatchObject({ url: "https://example.com/sea.jpg" });
  // Used, the form closes and the image is listed under Your images, chosen.
  expect(form()).toBeNull();
  const own = picker().querySelector<HTMLElement>('[data-collection="yours"]')!;
  expect(own.querySelector('[aria-label="sea.jpg"]')!.getAttribute("aria-pressed")).toBe("true");
  expect(own.querySelector(".backdrop-own-bar")!.textContent).toContain("Your images use");
  // The background in use cannot be removed; another of your images can.
  const remove = own.querySelector<HTMLButtonElement>('[aria-label="Remove sea.jpg"]')!;
  expect(remove.disabled).toBe(true);
  await act(async () => linkTile.click());
  await settle();
  const again = form()!.querySelector<HTMLInputElement>('input[type="url"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!.call(
      again,
      "https://example.com/hill.png",
    );
    again.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await submit();
  const sea = picker().querySelector<HTMLButtonElement>('[aria-label="Remove sea.jpg"]')!;
  expect(sea.disabled).toBe(false);
  await act(async () => sea.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.image.remove").at(-1)).toMatchObject({ id: "file:/backgrounds/sea.jpg" });
  expect(picker().querySelector('[aria-label="sea.jpg"]')).toBeNull();
  // Show in Finder reveals the folder.
  await act(async () => picker().querySelector<HTMLElement>(".backdrop-own-bar button")!.click());
  expect(runs(page, "cmux.settings.backdrop.image.reveal").length).toBe(1);
  page.unmount();
});

test("A wallpaper tile whose thumbnail fails shows an empty frame, not a broken image", async () => {
  const page = await renderPage({
    path: "/settings/appearance?focus=appearance.background",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  const tile = picker.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!;
  await act(async () => tile.querySelector("img")!.dispatchEvent(new window.Event("error")));
  await settle();
  expect(tile.querySelector("img")).toBeNull();
  expect(tile.querySelector("[data-thumb-missing]")).not.toBeNull();
  // The tile still chooses its wallpaper.
  await act(async () => tile.click());
  await settle();
  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({ key: "appearance.background", value: "starryNight" });
  page.unmount();
});

test("an art tile shows one title line; its full credit is the tooltip (macOS 15 tester: tile text overlapped)", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const long = "The Starry Night · Vincent van Gogh · 1889 · Museum of Modern Art, New York · Public domain";
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: [{ id: "starryNight", title: "The Starry Night", attribution: long }],
    }),
  );
  await settle();
  const tile = page.container.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!;
  // One text line under the thumbnail: the title, truncated by CSS; no wrapping credit line.
  expect([...tile.querySelectorAll("span")].filter((span) => span.textContent).map((span) => span.className)).toEqual([
    "backdrop-title",
  ]);
  expect(tile.textContent).toBe("The Starry Night");
  expect(tile.title).toBe(long);
  // A tile whose help text is not its credit keeps both, title first.
  const none = page.container.querySelector<HTMLButtonElement>(".backdrop-grid > button")!;
  expect(none.querySelector(".row-help")).toBeNull();
  page.unmount();
});
