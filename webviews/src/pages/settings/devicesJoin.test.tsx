// Settings > Devices on a Mac joined to a team with the one-line join: what it joined as, and its
// Screen sharing, Control and Your other Macs switches, all off until the person turns one on. Each switch sends one
// `cmux.settings.devices.join_consent`; the host's answer (re-read host lists) is what the switch shows.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { mockDevicesJoin } from "./mockProvider";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const group = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-devices-group="join"]');
const toggle = (container: HTMLElement, surface: string) =>
  group(container)!.querySelector<HTMLButtonElement>(`[data-devices-join-consent="${surface}"] [role="switch"]`)!;

test("a Mac that is not joined shows no join group", async () => {
  const page = await renderPage({ path: "/settings/devices" });
  await settle();
  expect(group(page.container)).toBeNull();
  page.unmount();
});

test("a joined Mac shows what it joined as, with every switch off", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesJoin: mockDevicesJoin } });
  await settle();
  const element = group(page.container)!;
  expect(element.querySelector("[data-devices-join]")!.textContent).toBe("Joined to Example Team as studio");
  expect(toggle(page.container, "screen").getAttribute("aria-checked")).toBe("false");
  expect(toggle(page.container, "control").getAttribute("aria-checked")).toBe("false");
  expect(element.textContent).toContain("Screen sharing");
  expect(element.textContent).toContain("Control");
  expect(toggle(page.container, "signedInMachines").getAttribute("aria-checked")).toBe("false");
  expect(element.textContent).toContain("Your other Macs");
  page.unmount();
});

test("each switch sends one join_consent and shows the host's answer", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesJoin: mockDevicesJoin } });
  await settle();
  const sent = () =>
    page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.join_consent").map((e) => e.params);
  await act(async () => toggle(page.container, "screen").click());
  await settle();
  expect(sent()).toEqual([{ surface: "screen", on: true }]);
  expect(toggle(page.container, "screen").getAttribute("aria-checked")).toBe("true");
  expect(toggle(page.container, "control").getAttribute("aria-checked")).toBe("false");
  await act(async () => toggle(page.container, "screen").click());
  await settle();
  expect(sent()).toEqual([
    { surface: "screen", on: true },
    { surface: "screen", on: false },
  ]);
  expect(toggle(page.container, "screen").getAttribute("aria-checked")).toBe("false");
  page.unmount();
});

test("while a consent write is in flight both switches are disabled", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: { devicesJoin: { ...mockDevicesJoin, busy: true } },
  });
  await settle();
  expect(toggle(page.container, "screen").hasAttribute("disabled")).toBe(true);
  expect(toggle(page.container, "control").hasAttribute("disabled")).toBe(true);
  await act(async () => toggle(page.container, "screen").click());
  await settle();
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.join_consent")).toEqual([]);
  page.unmount();
});

test("while acpmux's record is unknown every switch is disabled and one action turns them all off", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: {
      devicesJoin: {
        ...mockDevicesJoin,
        known: false,
        revoke_all: "Turn both off",
        error: "This Mac could not read what it allows.",
      },
    },
  });
  await settle();
  expect(toggle(page.container, "screen").hasAttribute("disabled")).toBe(true);
  expect(toggle(page.container, "control").hasAttribute("disabled")).toBe(true);
  await act(async () => toggle(page.container, "screen").click());
  await settle();
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.join_consent")).toEqual([]);
  const revoke = page.container.querySelector<HTMLButtonElement>('[data-devices-join-action="revokeAll"]');
  expect(revoke?.textContent).toBe("Turn both off");
  await act(async () => revoke?.click());
  await settle();
  expect(
    page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.join_consent").map((entry) => entry.params),
  ).toEqual([
    { surface: "screen", on: false },
    { surface: "control", on: false },
    { surface: "signedInMachines", on: false },
  ]);
  page.unmount();
});

test("with acpmux's record known there is no turn-both-off action", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesJoin: mockDevicesJoin } });
  await settle();
  expect(page.container.querySelector('[data-devices-join-action="revokeAll"]')).toBeNull();
  page.unmount();
});

test("the host's refusal of an on that is not the person's own click shows under the switches, never silently", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: { devicesJoin: mockDevicesJoin },
    setup: (provider) => {
      provider.joinConsentRefusal = "Only a click by the person at this Mac can allow this.";
    },
  });
  await settle();
  await act(async () => toggle(page.container, "control").click());
  await settle();
  const alert = group(page.container)!.querySelector('[role="alert"]');
  expect(alert?.textContent).toBe("Only a click by the person at this Mac can allow this.");
  expect(toggle(page.container, "control").getAttribute("aria-checked")).toBe("false");
  expect(toggle(page.container, "control").hasAttribute("disabled")).toBe(false);
  page.provider.joinConsentRefusal = null;
  await act(async () => toggle(page.container, "control").click());
  await settle();
  expect(group(page.container)!.querySelector('[role="alert"]')).toBeNull();
  expect(toggle(page.container, "control").getAttribute("aria-checked")).toBe("true");
  page.unmount();
});

test("a reply that carries the host's reason shows it under the switches", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: { devicesJoin: mockDevicesJoin },
    setup: (provider) => {
      provider.joinConsentReplyError = "Still off: another change to these switches is being written.";
    },
  });
  await settle();
  await act(async () => toggle(page.container, "control").click());
  await settle();
  expect(group(page.container)!.querySelector('[role="alert"]')?.textContent).toBe(
    "Still off: another change to these switches is being written.",
  );
  expect(toggle(page.container, "control").getAttribute("aria-checked")).toBe("false");
  page.unmount();
});

test("a write the host could not make shows the host's reason under the switches", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: {
      devicesJoin: {
        ...mockDevicesJoin,
        error: "Still off: Touch ID or your login password was cancelled, so this Mac could not confirm it was you.",
      },
    },
  });
  await settle();
  expect(group(page.container)!.querySelector('[role="alert"]')?.textContent).toBe(
    "Still off: Touch ID or your login password was cancelled, so this Mac could not confirm it was you.",
  );
  page.unmount();
});
