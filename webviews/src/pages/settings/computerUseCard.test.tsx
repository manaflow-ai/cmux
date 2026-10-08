// Agents > Computer Use Setup: the card shows the helper's real grants (host lists
// `computer_use`, the app's ComputerUseSetup), follows each change live, says why the grants are
// unknown while Computer Use is off, and its buttons run the shared catalog actions.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { ComputerUseState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="computer-use"]');
const grants = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-granted]")].map((badge) => badge.dataset.granted);

test("the card shows each grant and follows a change without a reload", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  const ready: ComputerUseState = { phase: "ready", accessibility: true, screen_recording: false, helper: "cmux Computer Use" };
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: ready }));
  await settle();
  expect(grants(card(page.container)!)).toEqual(["true", "false"]);
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: { ...ready, screen_recording: true } }));
  await settle();
  expect(grants(card(page.container)!)).toEqual(["true", "true"]);
  page.unmount();
});

test("off, the grants are unknown and the card says to turn Computer Use on", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  const off: ComputerUseState = { phase: "off", accessibility: null, screen_recording: null, helper: null };
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: off }));
  await settle();
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("off");
  expect(grants(element)).toEqual([]);
  expect(element.textContent).toContain("Turn on Computer Use");
  page.unmount();
});

test("the buttons run the shared actions; a policy lock hides the card", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  for (const action of ["palette.computerUse.accessibility", "palette.computerUse.screenRecording", "palette.computerUse.setup"]) {
    await act(async () => card(page.container)!.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!.click());
    await settle();
    expect(page.provider.log.some((entry) => entry.op === "cmux.app.action.run" && (entry.params as { action: string }).action === action)).toBe(true);
  }
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { phase: "disabled_by_policy", accessibility: null, screen_recording: null, helper: null },
    }),
  );
  await settle();
  expect(card(page.container)).toBeNull();
  page.unmount();
});
