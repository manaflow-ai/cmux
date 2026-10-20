// This Workspace's Opacity over a picture (#22378 follow-up): the window never paints a workspace's
// tint below the legibility floor either, so its slider starts at the floor the app reports, says
// why, and is disabled when the floor leaves it no travel, like the All Workspaces row.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run, settle } = await import("./testing");

const OPACITY = "appearance.backgroundOpacity";

async function workspaceSlider(floor: number | null) {
  const page = await renderPage({
    path: "/settings/appearance?workspace=ws-1",
    mock: { workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: "starryNight", opacity: null }] },
  });
  await settle();
  await run(() =>
    page.provider.setHost({ ...page.provider.host, derived_min: floor === null ? {} : { [OPACITY]: floor } }),
  );
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  await act(async () => picker.querySelector<HTMLInputElement>('[aria-label="This Workspace (Research)"]')!.click());
  await settle();
  const row = picker.querySelector<HTMLElement>("[data-workspace-opacity]")!;
  return { page, row, slider: row.querySelector<HTMLInputElement>('input[type="range"]')! };
}

test("over a picture This Workspace's Opacity starts at the legibility floor and says why", async () => {
  const { page, row, slider } = await workspaceSlider(0.62);
  expect(slider.min).toBe("0.65");
  expect(slider.max).toBe("0.95");
  expect(slider.disabled).toBe(false);
  expect(row.textContent).toContain("65%");
  page.unmount();
});

test("a floor at the 95% cap leaves This Workspace's Opacity no travel: it is disabled", async () => {
  const { page, slider } = await workspaceSlider(0.97);
  expect(slider.min).toBe("0.95");
  expect(slider.disabled).toBe(true);
  page.unmount();
});

test("without a floor This Workspace's Opacity keeps its whole range", async () => {
  const { page, row, slider } = await workspaceSlider(null);
  expect(slider.min).toBe("0");
  expect(slider.max).toBe("0.95");
  expect(row.textContent).not.toContain("readable");
  page.unmount();
});
