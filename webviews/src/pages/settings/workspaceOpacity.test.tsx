// This Workspace's Opacity over Art is the tint over the workspace's picture. The window paints no
// tint over art when the workspace shows no picture, so the slider shows only while it has one:
// its own picture, or the All Workspaces picture it follows.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

async function thisWorkspace(appBackground: string, workspaceValue: string | null) {
  const page = await renderPage({
    path: "/settings/appearance?workspace=ws-1",
    mock: {
      values: { "appearance.background": appBackground },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: workspaceValue, opacity: null }],
    },
  });
  await settle();
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  await act(async () => picker.querySelector<HTMLInputElement>('[aria-label="This Workspace (Research)"]')!.click());
  await settle();
  return { page, picker, slider: () => picker.querySelector("[data-workspace-opacity]") };
}

test("the slider shows over the workspace's own picture or the one it follows", async () => {
  const own = await thisWorkspace("none", "starryNight");
  expect(own.slider()).not.toBeNull();
  own.page.unmount();
  const follows = await thisWorkspace("starryNight", null);
  expect(follows.slider()).not.toBeNull();
  follows.page.unmount();
});

test("with this workspace's own No wallpaper there is no Opacity over Art slider", async () => {
  const none = await thisWorkspace("starryNight", "none");
  expect(none.slider()).toBeNull();
  none.page.unmount();
  // Following All Workspaces' None, the window may still show its own picture (appearance.set
  // scope=window), which the page does not see, so the slider stays.
  const followsNone = await thisWorkspace("none", null);
  expect(followsNone.slider()).not.toBeNull();
  followsNone.page.unmount();
});

test("choosing No wallpaper for this workspace takes the slider away; a picture brings it back", async () => {
  const { page, picker, slider } = await thisWorkspace("none", "starryNight");
  expect(slider()).not.toBeNull();
  await act(async () => picker.querySelector<HTMLButtonElement>('[aria-label="No wallpaper"]')!.click());
  await settle();
  expect(slider()).toBeNull();
  await act(async () => picker.querySelector<HTMLButtonElement>('[aria-label="The Starry Night"]')!.click());
  await settle();
  expect(slider()).not.toBeNull();
  page.unmount();
});

// "Opacity should go all the way to 100%" (2026-10-21): at 100% the workspace hides its picture.
test("This Workspace's Opacity over Art reaches 100%", async () => {
  const { page, slider } = await thisWorkspace("none", "starryNight");
  const input = slider()!.querySelector<HTMLInputElement>('input[type="range"]')!;
  expect(input.min).toBe("0");
  expect(input.max).toBe("1");
  page.unmount();
});
