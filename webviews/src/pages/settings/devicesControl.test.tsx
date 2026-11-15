// Settings > Devices: Control from this Mac (one switch per owned machine, sent as one
// `cmux.settings.devices.remote_control`), and on the target Mac the one-time ask to trust another
// Mac's key and the keys it trusts (`cmux.settings.devices.grantor_trust`). Every text comes from
// the host; an older host that sends none of these fields draws nothing new.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { mockDevicesControl, mockDevicesJoin, mockGrantorAsk, mockGrantors } from "./mockProvider";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, ops } = await import("./testing");

const group = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-devices-group="control"]');
const row = (container: HTMLElement, id: string) =>
  group(container)!.querySelector<HTMLElement>(`[data-devices-control-row="${id}"]`)!;
const toggle = (container: HTMLElement, id: string) =>
  row(container, id).querySelector<HTMLButtonElement>('[role="switch"]')!;

test("an older host without the new fields draws no control group, ask or trusted Macs", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesJoin: mockDevicesJoin } });
  await settle();
  expect(group(page.container)).toBeNull();
  expect(page.container.querySelector("[data-devices-grantor-ask]")).toBeNull();
  expect(page.container.querySelector("[data-devices-grantor]")).toBeNull();
  page.unmount();
});

test("one row per owned machine with its switch state, detail and this Mac's words", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesControl: mockDevicesControl } });
  await settle();
  const element = group(page.container)!;
  expect(element.querySelector(".group-title")!.textContent).toBe("Control from this Mac");
  expect(element.querySelector("[data-devices-control-this-words]")!.textContent).toContain(
    "maple orbit lantern quiet",
  );
  const ids = [...element.querySelectorAll<HTMLElement>("[data-devices-control-row]")].map(
    (node) => node.dataset.devicesControlRow,
  );
  expect(ids).toEqual(["m_mini", "m_studio", "m_air", "m_lab"]);
  expect(row(page.container, "m_mini").querySelector(".row-title")!.textContent).toBe("mini-7");
  expect(toggle(page.container, "m_mini").getAttribute("aria-checked")).toBe("true");
  expect(toggle(page.container, "m_studio").getAttribute("aria-checked")).toBe("false");
  expect(row(page.container, "m_mini").textContent).toContain("Turned on from this Mac · 5 min ago");
  // Offline: the switch cannot be used.
  expect(toggle(page.container, "m_air").hasAttribute("disabled")).toBe(true);
  // A failed status reads as an alert.
  expect(row(page.container, "m_lab").querySelector('[role="alert"]')!.textContent).toBe(
    "lab-mac did not answer. Try again.",
  );
  page.unmount();
});

test("the switch sends remote_control with the machine and the new state, then shows the host's answer", async () => {
  const page = await renderPage({ path: "/settings/devices", mock: { devicesControl: mockDevicesControl } });
  await settle();
  await act(async () => toggle(page.container, "m_mini").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.devices.remote_control")).toEqual([{ id: "m_mini", on: false }]);
  expect(toggle(page.container, "m_mini").getAttribute("aria-checked")).toBe("false");
  page.unmount();
});

test("a machine that has not trusted this Mac yet waits for the one-time ask and shows the words", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: { devicesControl: mockDevicesControl, devicesControlAsk: ["m_studio"] },
  });
  await settle();
  await act(async () => toggle(page.container, "m_studio").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.devices.remote_control")).toEqual([{ id: "m_studio", on: true }]);
  const studio = row(page.container, "m_studio");
  expect(studio.dataset.devicesControlStatus).toBe("ask_pending");
  expect(studio.querySelector("[data-devices-control-words]")!.textContent).toBe("maple orbit lantern quiet");
  expect(toggle(page.container, "m_studio").getAttribute("aria-checked")).toBe("false");
  page.unmount();
});

test("a busy row and a refused set: the switch is disabled while busy and the refusal is an alert", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: {
      devicesControl: {
        ...mockDevicesControl,
        rows: mockDevicesControl.rows.map((r) => (r.id === "m_studio" ? { ...r, busy: true } : r)),
      },
      failing: { "cmux.settings.devices.remote_control": "cmux.settings.refused" },
    },
  });
  await settle();
  expect(toggle(page.container, "m_studio").hasAttribute("disabled")).toBe(true);
  await act(async () => toggle(page.container, "m_mini").click());
  await settle();
  expect(row(page.container, "m_mini").querySelector('[role="alert"]')).not.toBeNull();
  page.unmount();
});

test("the target Mac's ask: Allow trusts the key, Not now dismisses it", async () => {
  const join = { ...mockDevicesJoin, grantor_ask: mockGrantorAsk, grantors: [] };
  const page = await renderPage({ path: "/settings/devices", mock: { devicesJoin: join } });
  await settle();
  const ask = page.container.querySelector<HTMLElement>(`[data-devices-grantor-ask="${mockGrantorAsk.id}"]`)!;
  expect(ask.textContent).toContain(mockGrantorAsk.title);
  expect(ask.querySelector("[data-devices-grantor-words]")!.textContent).toBe("maple orbit lantern quiet");
  await act(async () => ask.querySelector<HTMLButtonElement>('[data-devices-grantor-action="allow"]')!.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.devices.grantor_trust")).toEqual([{ id: mockGrantorAsk.id, trusted: true }]);
  expect(page.container.querySelector("[data-devices-grantor-ask]")).toBeNull();
  expect(page.container.querySelector(`[data-devices-grantor="${mockGrantorAsk.id}"]`)).not.toBeNull();
  page.unmount();

  const again = await renderPage({ path: "/settings/devices", mock: { devicesJoin: join } });
  await settle();
  await act(async () =>
    again.container.querySelector<HTMLButtonElement>('[data-devices-grantor-action="dismiss"]')!.click(),
  );
  await settle();
  expect(ops(again.provider, "cmux.settings.devices.grantor_trust")).toEqual([
    { id: mockGrantorAsk.id, trusted: false },
  ]);
  expect(again.container.querySelector("[data-devices-grantor-ask]")).toBeNull();
  again.unmount();
});

test("a trusted Mac is listed with Remove, which sends trusted=false", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: { devicesJoin: { ...mockDevicesJoin, grantor_ask: null, grantors: mockGrantors } },
  });
  await settle();
  const pinned = page.container.querySelector<HTMLElement>(`[data-devices-grantor="${mockGrantors[0]!.id}"]`)!;
  expect(pinned.textContent).toContain(mockGrantors[0]!.title);
  expect(pinned.textContent).toContain(mockGrantors[0]!.subtitle);
  await act(async () => pinned.querySelector<HTMLButtonElement>('[data-devices-grantor-action="remove"]')!.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.devices.grantor_trust")).toEqual([
    { id: mockGrantors[0]!.id, trusted: false },
  ]);
  expect(page.container.querySelector(`[data-devices-grantor="${mockGrantors[0]!.id}"]`)).toBeNull();
  page.unmount();
});
