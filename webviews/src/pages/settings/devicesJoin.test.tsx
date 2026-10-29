// Settings > Devices on a Mac joined to a team with the one-line join: what it joined as, and its
// Screen sharing and Control switches, both off until the person turns one on. Each switch sends one
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

test("a joined Mac shows what it joined as, with both switches off", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesJoin: mockDevicesJoin } });
  await settle();
  const element = group(page.container)!;
  expect(element.querySelector("[data-devices-join]")!.textContent).toBe("Joined to Example Team as studio");
  expect(toggle(page.container, "screen").getAttribute("aria-checked")).toBe("false");
  expect(toggle(page.container, "control").getAttribute("aria-checked")).toBe("false");
  expect(element.textContent).toContain("Screen sharing");
  expect(element.textContent).toContain("Control");
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
