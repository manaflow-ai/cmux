// R82 commit 2: Spaces & Profiles and Machines are drawn by the page from the host lists
// (`cmux.settings.host.lists`, live through `cmux.settings.host.changed`), not an "open in
// window" link, and every browser profile edit runs its `browserProfile.*` action with the
// profile as the target.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, ops } = await import("./testing");

test("General lists the spaces and Browser the browser profiles, with no open-in-window link", async () => {
  // The old section route (`#/settings/rooms`, `app settings rooms`) opens General.
  const page = await renderPage({ path: "/settings/rooms" });
  expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("general");
  expect(page.container.textContent).toContain("Work");
  expect(page.container.querySelectorAll('[data-card="rooms"] [data-host-row]').length).toBe(2);
  page.unmount();
  const browser = await renderPage({ path: "/settings/browser" });
  const text = browser.container.textContent ?? "";
  expect(text).toContain("Browser Profiles");
  expect(text).toContain("Google Chrome · Work");
  expect(text).not.toContain("Open in Window");
  browser.unmount();
});

test("Machines lists the saved machines; a host change updates the list without a reload", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  expect(page.container.textContent).toContain("build-mac");
  await act(async () => {
    page.provider.setHost({ ...page.provider.host, machines: [] });
  });
  await settle();
  expect(page.container.textContent).toContain("No saved machines.");
  page.unmount();
});

test("a machine row draws its icon in the row's mark: an emoji, a stored image, else the name's initial", async () => {
  // cx-qno.11.4: a machine's icon (the home session registry's) shows on its Settings row as a
  // space's does; an SF Symbol is not drawable here, so a plain machine shows its initial.
  const asset = `svg:sha256-${"a".repeat(64)}`;
  const page = await renderPage({ path: "/settings/machines" });
  const mark = () => page.container.querySelector('[data-card="machines"] [data-host-row] .host-avatar');
  expect(mark()?.textContent).toBe("B");
  await act(async () => {
    page.provider.setHost({ ...page.provider.host, machines: [{ ...page.provider.host.machines[0]!, icon: "🚀" }] });
  });
  await settle();
  expect(mark()?.textContent).toBe("🚀");
  await act(async () => {
    page.provider.setHost({ ...page.provider.host, machines: [{ ...page.provider.host.machines[0]!, icon: asset }] });
  });
  await settle();
  expect(mark()?.querySelector("img")?.getAttribute("src")).toBe(`icon/${encodeURIComponent(asset)}`);
  page.unmount();
});

test("browser profile edits run the profile's actions with its target", async () => {
  const page = await renderPage({ path: "/settings/browser" });
  const row = page.container.querySelector<HTMLElement>('[data-profile="p-work"]')!;
  await act(async () => row.querySelector<HTMLButtonElement>(".host-toggle")!.click());
  await act(async () => row.querySelector<HTMLButtonElement>('[aria-label="grey"]')!.click());
  await settle();
  const run = page.provider.log.filter((entry) => entry.op === "cmux.app.action.run").at(-1)!;
  expect(run.params).toEqual({
    action: "browserProfile.setColor",
    args: { color: "grey" },
    target: "browser-profile:p-work",
  });
  expect(page.provider.host.browser_profiles.find((profile) => profile.id === "p-work")!.color).toBe("grey");

  await act(async () => page.container.querySelector<HTMLButtonElement>("[data-new-profile]")!.click());
  await settle();
  expect(page.container.querySelectorAll("[data-profile]").length).toBe(3);
  // The default profile offers no delete.
  const first = page.container.querySelector<HTMLElement>('[data-profile="p-default"]')!;
  await act(async () => first.querySelector<HTMLButtonElement>(".host-toggle")!.click());
  expect(first.querySelector("[data-delete-profile]")).toBeNull();
  page.unmount();
});

test("a space and a browser profile with a stored image or SVG icon draw it from the host's icon resource", async () => {
  // cx-qno.2.3: an `svg:`/`image:` asset ref draws as the host's PNG of it (`icon/<ref>`), never
  // as the ref's text.
  const asset = `svg:sha256-${"b".repeat(64)}`;
  const src = `icon/${encodeURIComponent(asset)}`;
  const general = await renderPage({ path: "/settings/rooms" });
  await act(async () => {
    const rooms = general.provider.host.rooms!.map((room, index) => (index === 0 ? { ...room, icon: asset } : room));
    general.provider.setHost({ ...general.provider.host, rooms });
  });
  await settle();
  const room = general.container.querySelector('[data-card="rooms"] [data-host-row]')!;
  expect(room.querySelector("img")?.getAttribute("src")).toBe(src);
  expect(room.textContent).not.toContain("svg:");
  general.unmount();

  const browser = await renderPage({ path: "/settings/browser" });
  await act(async () => {
    const profiles = browser.provider.host.browser_profiles.map((profile) =>
      profile.id === "p-work" ? { ...profile, icon: asset } : profile,
    );
    browser.provider.setHost({ ...browser.provider.host, browser_profiles: profiles });
  });
  await settle();
  const avatar = browser.container.querySelector('[data-profile="p-work"] .host-avatar')!;
  expect(avatar.querySelector("img")?.getAttribute("src")).toBe(src);
  expect(avatar.textContent).toBe("");
  browser.unmount();
});

test("Development shows only when the host is a DEV build, however it is reached", async () => {
  const dev = await renderPage({ path: "/settings/development" });
  expect(dev.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("development");
  expect(dev.container.querySelector('[data-row-key="macScreen.debug.relayOnly"]')).not.toBeNull();
  expect(dev.container.querySelector('[data-section-link="development"]')).not.toBeNull();
  dev.unmount();
  // NIGHTLY and Release: the deep link (and the relay key's focus link) open the default page.
  for (const path of ["/settings/development", "/settings/development?focus=macScreen.debug.relayOnly"]) {
    const page = await renderPage({
      path,
      setup: (provider) => provider.setHost({ ...provider.host, dev_build: false }),
    });
    expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("general");
    expect(page.container.querySelector('[data-row-key="macScreen.debug.relayOnly"]')).toBeNull();
    expect(page.container.querySelector('[data-section-link="development"]')).toBeNull();
    page.unmount();
  }
});

test("Devices shows in NIGHTLY and Release builds too, from the sidebar and its deep link", async () => {
  // Mac Screen's sharing switch, permissions and relays live only here; release builds use the
  // built-in device hub, so a non-DEV host must still list and open the category.
  const page = await renderPage({
    path: "/settings/devices",
    setup: (provider) => provider.setHost({ ...provider.host, dev_build: false }),
  });
  expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("devices");
  expect(page.container.querySelector('[data-section-link="devices"]')).not.toBeNull();
  expect(page.container.querySelector('[data-section-link="development"]')).toBeNull();
  page.unmount();
});

test("Machines offers Add Device…, which opens the one Add Device card through the palette's action", async () => {
  // add-device-DESIGN.md 2.2: one entry for every new device. The page passes no way, so it only
  // opens the card; the card hands off to Add Machine or Add Server and never approves by itself.
  const page = await renderPage({ path: "/settings/machines" });
  const button = page.container.querySelector<HTMLButtonElement>('[data-card="machines"] [data-add-device]');
  expect(button).not.toBeNull();
  expect(button!.textContent).toBe("Add Device…");
  expect(page.container.querySelector("[data-add-server]")).toBeNull();
  await act(async () => button!.click());
  await settle();
  const run = page.provider.log.filter((entry) => entry.op === "cmux.app.action.run").at(-1)!;
  expect(run.params).toEqual({ action: "device.add", args: {} });
  page.unmount();
});

test("Devices lists every device with its role and state, and the recent activity", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  const rows = page.container.querySelectorAll('[data-card="devices"] [data-device-row]');
  expect(Array.from(rows).map((row) => row.getAttribute("data-device-row"))).toEqual([
    "peer:mini-7",
    "paired:dv_leo",
    "phone:p1",
  ]);
  expect(page.container.textContent).toContain("Runs your agents · Connected");
  expect(page.container.querySelector("[data-device-activity]")?.textContent).toContain("Added mini-7");
  page.unmount();
});

test("Remove asks once more, then removes the device everywhere and the list updates", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  const remove = () => page.container.querySelector<HTMLButtonElement>('[data-remove-device="peer:mini-7"]');
  await act(async () => remove()!.click());
  await settle();
  expect(remove()!.textContent).toBe("Remove for Good");
  expect(page.provider.log.some((entry) => entry.op === "cmux.settings.devices.remove")).toBe(false);
  await act(async () => remove()!.click());
  await settle();
  const call = page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.remove").at(-1)!;
  expect(call.params).toEqual({ id: "peer:mini-7" });
  expect(remove()).toBeNull();
  page.unmount();
});

test("only a paired client machine or phone has a Full access switch, off until turned on, saying what it allows", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  const card = page.container.querySelector('[data-card="devices"]')!;
  const lines = card.querySelectorAll("[data-device-full-access]");
  expect(Array.from(lines).map((line) => line.getAttribute("data-device-full-access"))).toEqual([
    "paired:dv_leo",
    "phone:p1",
  ]);
  const line = () => card.querySelector('[data-device-full-access="paired:dv_leo"]')!;
  const toggle = () => line().querySelector<HTMLButtonElement>('[role="switch"]')!;
  expect(toggle().getAttribute("aria-checked")).toBe("false");
  expect(line().textContent).toContain("Full access");
  expect(line().textContent).toContain("Its chats edit files and run commands here without asking");
  await act(async () => toggle().click());
  await settle();
  const on = page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.full_access").at(-1)!;
  expect(on.params).toEqual({ id: "paired:dv_leo", on: true });
  expect(toggle().getAttribute("aria-checked")).toBe("true");
  // Revoking is the same switch, and takes effect with the call.
  await act(async () => toggle().click());
  await settle();
  const off = page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.full_access").at(-1)!;
  expect(off.params).toEqual({ id: "paired:dv_leo", on: false });
  expect(toggle().getAttribute("aria-checked")).toBe("false");
  // A phone paired with this Mac: the same switch, by its phone row's id.
  const phone = card.querySelector('[data-device-full-access="phone:p1"]')!;
  expect(phone.querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("false");
  await act(async () => phone.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  await settle();
  const phoneOn = page.provider.log.filter((entry) => entry.op === "cmux.settings.devices.full_access").at(-1)!;
  expect(phoneOn.params).toEqual({ id: "phone:p1", on: true });
  page.unmount();
});

// A machine's color (appearance.machineColors): each Machines row shows the color its marks draw in
// (the sidebar row, the tab badge), a well that picks another, and Automatic, which takes the pick
// back. The map is keyed by the machine's color key (its name trimmed and lowercased, as the app
// keys it), and a write keeps every other machine's pick.
test("a machine row picks its color and Automatic takes the pick back", async () => {
  const page = await renderPage({
    path: "/settings/machines",
    mock: { values: { "appearance.machineColors": { "big-red": "cyan" } } },
  });
  const row = () => page.container.querySelector<HTMLElement>('[data-card="machines"] [data-host-row="ssh:build"]')!;
  const well = () => row().querySelector<HTMLInputElement>('input[type="color"]')!;
  // Automatic: the well shows the color the app draws, and there is nothing to take back.
  expect(well().value).toBe("#7f5fa8");
  expect(row().querySelector("[data-machine-color-reset]")).toBeNull();
  // The card draws the row: no plain map editor for it below.
  expect(page.container.querySelector('.row[data-row-key="appearance.machineColors"]')).toBeNull();

  await act(async () => {
    well().value = "#12ab34";
    well().dispatchEvent(new Event("change", { bubbles: true }));
  });
  await settle();
  expect(ops(page.provider, "cmux.settings.set")).toEqual([
    { key: "appearance.machineColors", value: { "big-red": "cyan", "build-mac": "#12ab34" } },
  ]);

  await act(async () => row().querySelector<HTMLButtonElement>("[data-machine-color-reset]")!.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: "appearance.machineColors",
    value: { "big-red": "cyan" },
  });
  expect(row().querySelector("[data-machine-color-reset]")).toBeNull();
  page.unmount();
});

test("a Cloud machine cmux made has its Dedicated agent machine switch; other machines have none", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  const cloud = {
    id: "cloud:vm_1",
    title: "sample-vm",
    subtitle: null,
    active: true,
    vm_host: { on: true, busy: false, error: null },
  };
  expect(page.container.querySelector("[data-machine-vm-host]")).toBeNull();
  await act(async () => {
    page.provider.setHost({ ...page.provider.host, machines: [...page.provider.host.machines, cloud] });
  });
  await settle();
  const switches = page.container.querySelectorAll("[data-machine-vm-host]");
  expect(switches.length).toBe(1);
  expect(switches[0]!.getAttribute("data-machine-vm-host")).toBe("cloud:vm_1");
  const toggle = switches[0]!.querySelector('[role="switch"]') as HTMLElement;
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  await act(async () => toggle.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.machines.vm_host")).toEqual([{ id: "cloud:vm_1", on: false }]);
  const after = page.container.querySelector('[data-machine-vm-host="cloud:vm_1"] [role="switch"]');
  expect(after?.getAttribute("aria-checked")).toBe("false");
  // The machine's own refusal shows under the switch.
  await act(async () => {
    page.provider.setHost({
      ...page.provider.host,
      machines: page.provider.host.machines.map((m) =>
        m.id === "cloud:vm_1" ? { ...m, vm_host: { on: false, busy: false, error: "vmHost stays off here" } } : m,
      ),
    });
  });
  await settle();
  expect(page.container.querySelector('[data-machine-vm-host] [role="alert"]')?.textContent).toBe(
    "vmHost stays off here",
  );
  page.unmount();
});
