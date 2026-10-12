// R82 commit 4: the Swift window's last cards are drawn by the page (the Theme section has its own
// test, themeStudio.test.tsx). The background picker (Change Background…, cx-t2x.4) previews and
// writes appearance.background on Appearance, Terminal shows the Ghostty facts,
// and Advanced shows the settings file and every problem of the last load.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

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
  await act(async () => {
    tile.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 200));
  });
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

test("Shuffle Daily is a tile that keeps appearance.background daily", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const tile = page.container.querySelector<HTMLButtonElement>('[data-card="backdrop"] [aria-label="Shuffle Daily"]')!;
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

  const none = picker.querySelector<HTMLButtonElement>('[aria-label="No wallpaper"]')!;
  const appPreviews = runs(page, "cmux.settings.preview").length;
  await act(async () => {
    none.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 200));
  });
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

test("sweeping the pointer across the picker previews nothing", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const tile = page.container.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!;
  await act(async () => {
    tile.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
    tile.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 200));
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
