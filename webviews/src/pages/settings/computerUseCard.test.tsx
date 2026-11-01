// Agents > Computer Use: one card holds the on/off switch (computerUse.enabled), Guided Setup (the
// onboarding step, #28997) and the helper's real grants (host lists `computer_use`, the app's
// ComputerUseSetup); it follows each change live and its buttons run the shared catalog actions.
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
  const ready: ComputerUseState = {
    phase: "ready",
    accessibility: true,
    screen_recording: false,
    helper: "cmux Computer Use",
  };
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: ready }));
  await settle();
  expect(grants(card(page.container)!)).toEqual(["true", "false"]);
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, computer_use: { ...ready, screen_recording: true } }),
  );
  await settle();
  expect(grants(card(page.container)!)).toEqual(["true", "true"]);
  page.unmount();
});

test("off, the card hides the grants and Guided Setup offers to turn Computer Use on", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  const off: ComputerUseState = { phase: "off", accessibility: null, screen_recording: null, helper: null };
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: off }));
  await settle();
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("off");
  expect(grants(element)).toEqual([]);
  expect(element.querySelector('[data-action="palette.computerUse.accessibility"]')).toBeNull();
  expect(element.textContent).toContain("Turns on Computer Use and walks you through");
  await act(async () => element.querySelector<HTMLButtonElement>('[data-action="palette.computerUse.setup"]')!.click());
  await settle();
  expect(
    page.provider.log.some(
      (entry) =>
        entry.op === "cmux.app.action.run" &&
        (entry.params as { action: string }).action === "palette.computerUse.setup",
    ),
  ).toBe(true);
  page.unmount();
});

test("the card draws the Computer Use switch once, and the switch turns Computer Use off", async () => {
  const page = await renderPage({ path: "/settings/agents", mock: { values: { "computerUse.enabled": true } } });
  await settle();
  const element = card(page.container)!;
  for (const key of ["computerUse.enabled", "computerUse.driver", "computerUse.livePreview"]) {
    expect(element.querySelector(`[data-row-key="${key}"]`)).not.toBeNull();
    expect(page.container.querySelectorAll(`[data-row-key="${key}"]`)).toHaveLength(1);
  }
  // The switch comes first, then Guided Setup.
  const rows = [...element.querySelectorAll<HTMLElement>("[data-row-key], [data-action-row]")];
  expect(rows[0]!.dataset.rowKey).toBe("computerUse.enabled");
  expect(rows[1]!.querySelector('[data-action="palette.computerUse.setup"]')).not.toBeNull();
  const toggle = element.querySelector<HTMLButtonElement>('[data-row-key="computerUse.enabled"] [role="switch"]')!;
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  await act(async () => toggle.click());
  await settle();
  expect(
    page.provider.log.some(
      (entry) =>
        entry.op === "cmux.settings.set" &&
        (entry.params as { key: string; value: unknown }).key === "computerUse.enabled" &&
        (entry.params as { value: unknown }).value === false,
    ),
  ).toBe(true);
  page.unmount();
});

test("a cmux build the legacy helper can't verify says legacy Computer Use is off", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  const state: ComputerUseState = {
    phase: "ready",
    accessibility: true,
    screen_recording: true,
    helper: "cmux Computer Use",
    host_unverified: true,
  };
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: state }));
  await settle();
  expect(card(page.container)!.textContent).toContain("Legacy Computer Use is off");
  page.unmount();
});

test("driver upstream in a build without its helper says Legacy runs instead", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  const state: ComputerUseState = {
    phase: "ready",
    accessibility: true,
    screen_recording: true,
    helper: "cmux Computer Use",
    upstream_fallback: true,
  };
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: state }));
  await settle();
  const text = card(page.container)!.textContent ?? "";
  expect(text).toContain("Upstream helper isn't in this build; using Legacy.");
  expect(text).not.toContain("Starting");
  page.unmount();
});

test("the buttons run the shared actions; a policy lock leaves only the rows", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  for (const action of [
    "palette.computerUse.accessibility",
    "palette.computerUse.screenRecording",
    "palette.computerUse.setup",
  ]) {
    await act(async () => card(page.container)!.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!.click());
    await settle();
    expect(
      page.provider.log.some(
        (entry) => entry.op === "cmux.app.action.run" && (entry.params as { action: string }).action === action,
      ),
    ).toBe(true);
  }
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { phase: "disabled_by_policy", accessibility: null, screen_recording: null, helper: null },
    }),
  );
  await settle();
  const locked = card(page.container)!;
  expect(locked.dataset.phase).toBe("disabled_by_policy");
  expect(locked.querySelector("[data-action]")).toBeNull();
  expect(grants(locked)).toEqual([]);
  expect(locked.querySelector('[data-row-key="computerUse.enabled"]')).not.toBeNull();
  page.unmount();
});

test("a failed helper has one Restart Helper action and recovers on a host update", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { phase: "failed", accessibility: null, screen_recording: null, helper: "cmux Computer Use" },
    }),
  );
  await settle();
  const element = card(page.container)!;
  expect(element.textContent).toContain("The cmux Computer Use helper did not respond.");
  const buttons = element.querySelectorAll<HTMLButtonElement>("button[data-action]");
  expect(buttons.length).toBe(1);
  expect(buttons[0]!.textContent).toBe("Restart Helper");
  await act(async () => buttons[0]!.click());
  await settle();
  expect(
    page.provider.log.some(
      (entry) =>
        entry.op === "cmux.app.action.run" &&
        (entry.params as { action: string }).action === "palette.computerUse.restart",
    ),
  ).toBe(true);
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { phase: "ready", accessibility: true, screen_recording: true, helper: "cmux Computer Use" },
    }),
  );
  await settle();
  expect(grants(card(page.container)!)).toEqual(["true", "true"]);
  expect(card(page.container)!.textContent).not.toContain("Restart Helper");
  page.unmount();
});
