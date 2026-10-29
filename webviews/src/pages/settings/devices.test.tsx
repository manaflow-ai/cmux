// Settings > Devices: the page draws the host's state (every text localized by the host) and sends
// each gesture as one `cmux.settings.devices.run`. Removal and relay deletion ask first; a relay
// secret is typed into a password field, sent once with Save, cleared, and never drawn back.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { mockDevicesState } from "./mockProvider";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="devices"]')!;
const nonRefresh = <Run extends { action: string }>(runs: readonly Run[]) =>
  runs.filter((run) => run.action !== "refresh");

async function open() {
  const page = await renderPage({ path: "/settings/devices" });
  await settle();
  return page;
}

test("the card shows this Mac with its badge and fingerprint and reads again when it opens", async () => {
  const page = await open();
  const element = card(page.container);
  expect(page.provider.deviceRuns[0]).toEqual({ action: "refresh" });
  expect(element.querySelector("[data-devices-status]")!.textContent).toBe("Connected");
  const self = element.querySelector<HTMLElement>('[data-devices-group="this"] [data-device="dev-mac-studio"]')!;
  expect(self.querySelector("[data-device-name]")!.textContent).toBe("Studio Mac");
  expect(self.querySelector("[data-device-badge]")!.textContent).toBe("This Mac");
  expect(self.querySelector("[data-device-fingerprint]")!.textContent).toContain("1A2B 3C4D 5E6F 7081 92A3 B4C5");
  expect(self.textContent).toContain("Mac");
  // This Mac has no access picker of its own.
  expect(self.querySelector("[data-device-access]")).toBeNull();
  // No sign-in button while signed in.
  expect(element.querySelector('[data-devices-action="signIn"]')).toBeNull();
  page.unmount();
});

test("other devices show presence and an access picker that sends setAccess", async () => {
  const page = await open();
  const element = card(page.container);
  const others = element.querySelector<HTMLElement>('[data-devices-group="others"]')!;
  const phone = others.querySelector<HTMLElement>('[data-device="dev-iphone"]')!;
  const laptop = others.querySelector<HTMLElement>('[data-device="dev-macbook"]')!;
  expect(phone.querySelector('[data-device-presence="online"]')!.textContent).toBe("Online");
  expect(laptop.querySelector('[data-device-presence="offline"]')!.textContent).toBe("Offline · seen 5 minutes ago");
  expect(laptop.querySelector("[data-device-shares]")!.textContent).toBe("Shares Mac Screen");
  expect(laptop.querySelector("[data-device-fingerprint]")).toBeNull();
  expect(phone.querySelector("[data-device-badge]")).toBeNull();
  const select = phone.querySelector<HTMLSelectElement>("[data-device-access] select")!;
  expect(select.value).toBe("full");
  expect([...select.options].map((option) => option.textContent)).toEqual([
    "No access",
    "Ask each time",
    "View only",
    "Full control",
  ]);
  await changeValue(select, "view");
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "setAccess", id: "dev-iphone", scope: "view" }]);
  expect(
    card(page.container).querySelector<HTMLSelectElement>('[data-device="dev-iphone"] [data-device-access] select')!
      .value,
  ).toBe("view");
  page.unmount();
});

test("Rename… opens a form that sends rename with the new name", async () => {
  const page = await open();
  const row = () => card(page.container).querySelector<HTMLElement>('[data-device="dev-iphone"]')!;
  await click(row().querySelector('[data-device-action="rename"]')!);
  const field = row().querySelector<HTMLInputElement>("[data-device-rename] input")!;
  expect(field.value).toBe("Aziz's iPhone");
  await changeValue(field, "  Pocket  ");
  await click(row().querySelector('[data-device-action="saveName"]')!);
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "rename", id: "dev-iphone", name: "Pocket" }]);
  expect(row().querySelector("[data-device-name]")!.textContent).toBe("Pocket");
  expect(row().querySelector("[data-device-rename]")).toBeNull();
  page.unmount();
});

test("Remove… asks for confirmation before it sends remove", async () => {
  const page = await open();
  const row = () => card(page.container).querySelector<HTMLElement>('[data-device="dev-macbook"]');
  await click(row()!.querySelector('[data-device-action="remove"]')!);
  const confirm = row()!.querySelector<HTMLElement>("[data-devices-confirm]")!;
  expect(confirm.textContent).toContain("Remove MacBook Pro?");
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([]);
  // Cancel sends nothing.
  await click(confirm.querySelector('[data-devices-confirm-action="cancel"]')!);
  expect(row()!.querySelector("[data-devices-confirm]")).toBeNull();
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([]);
  await click(row()!.querySelector('[data-device-action="remove"]')!);
  await click(row()!.querySelector('[data-devices-confirm-action="confirm"]')!);
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "remove", id: "dev-macbook" }]);
  expect(row()).toBeNull();
  page.unmount();
});

test("the sharing switch sends setSharing; a permission's button sends openPermission", async () => {
  const page = await open();
  const group = () => card(page.container).querySelector<HTMLElement>('[data-devices-group="sharing"]')!;
  expect(group().querySelector('[data-devices-permission="screenRecording"]')!.textContent).toContain("Allowed");
  expect(group().querySelector('[data-devices-permission="screenRecording"] button')).toBeNull();
  await click(
    group().querySelector('[data-devices-permission="accessibility"] [data-devices-action="openPermission"]')!,
  );
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "openPermission", id: "accessibility" }]);
  const toggle = group().querySelector<HTMLButtonElement>('[data-devices-sharing] [role="switch"]')!;
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  await click(toggle);
  expect(nonRefresh(page.provider.deviceRuns).at(-1)).toEqual({ action: "setSharing", on: false });
  // Off: the permission rows go away.
  expect(group().querySelector("[data-devices-permission]")).toBeNull();
  expect(group().querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("false");
  page.unmount();
});

test("Add Relay… switches its secret fields by mode, sends saveRelay once and clears the secret", async () => {
  const page = await open();
  const group = () => card(page.container).querySelector<HTMLElement>('[data-devices-group="relays"]')!;
  const form = () => group().querySelector<HTMLElement>('[data-relay-editor="new"]');
  const field = (name: string) => form()!.querySelector<HTMLInputElement>(`[data-relay-field="${name}"]`);
  expect(group().textContent).toContain("Used when your devices cannot connect directly.");
  await click(group().querySelector('[data-devices-action="addRelay"]')!);
  // Shared secret first: one password field, no username or password.
  expect(field("secret")!.type).toBe("password");
  expect(field("username")).toBeNull();
  expect(field("password")).toBeNull();
  await changeValue(form()!.querySelector<HTMLSelectElement>('[data-relay-field="mode"] select')!, "static");
  expect(field("secret")).toBeNull();
  expect(field("username")).not.toBeNull();
  expect(field("password")!.type).toBe("password");
  await changeValue(form()!.querySelector<HTMLSelectElement>('[data-relay-field="mode"] select')!, "shared_secret");
  await changeValue(field("name")!, " Home TURN ");
  await changeValue(
    form()!.querySelector<HTMLTextAreaElement>('[data-relay-field="urls"]') as unknown as HTMLInputElement,
    " turn:a.example:3478 \nturns:b.example:443, turn:c.example:3478 ,\n",
  );
  await changeValue(field("priority")!, "5");
  await changeValue(field("secret")!, "s3cret-value");
  await click(form()!.querySelector('[data-relay-action="save"]')!);
  const saves = page.provider.deviceRuns.filter((run) => run.action === "saveRelay");
  expect(saves).toEqual([
    {
      action: "saveRelay",
      relay: {
        name: "Home TURN",
        urls: ["turn:a.example:3478", "turns:b.example:443", "turn:c.example:3478"],
        mode: "shared_secret",
        secret: "s3cret-value",
        enabled: true,
        priority: 5,
      },
    },
  ]);
  // Saved: the form closes, the relay is listed, and the secret appears nowhere on the page.
  expect(form()).toBeNull();
  expect(group().querySelector('[data-relay="relay-3"]')!.textContent).toContain("Home TURN");
  expect(page.container.innerHTML).not.toContain("s3cret-value");
  page.unmount();
});

test("a refused save keeps the form, shows the host's error and clears the secret", async () => {
  const page = await open();
  const group = () => card(page.container).querySelector<HTMLElement>('[data-devices-group="relays"]')!;
  await click(group().querySelector('[data-devices-action="addRelay"]')!);
  const form = () => group().querySelector<HTMLElement>('[data-relay-editor="new"]')!;
  await changeValue(form().querySelector<HTMLInputElement>('[data-relay-field="name"]')!, "No secret");
  await changeValue(
    form().querySelector<HTMLTextAreaElement>('[data-relay-field="urls"]') as unknown as HTMLInputElement,
    "turn:x.example:3478",
  );
  await click(form().querySelector('[data-relay-action="save"]')!);
  expect(form().querySelector("[data-devices-error]")!.textContent).toBe("Enter the relay's secret.");
  expect(form().querySelector<HTMLInputElement>('[data-relay-field="secret"]')!.value).toBe("");
  page.unmount();
});

test("Edit… with an empty secret keeps the saved one (the draft leaves it out)", async () => {
  const page = await open();
  const row = () => card(page.container).querySelector<HTMLElement>('[data-relay="relay-1"]')!;
  await click(row().querySelector('[data-relay-action="edit"]')!);
  const form = () => row().querySelector<HTMLElement>('[data-relay-editor="relay-1"]')!;
  const secret = form().querySelector<HTMLInputElement>('[data-relay-field="secret"]')!;
  expect(secret.value).toBe("");
  expect(secret.placeholder).toBe("Leave empty to keep the saved secret");
  await changeValue(form().querySelector<HTMLInputElement>('[data-relay-field="name"]')!, "cmux TURN 2");
  await click(form().querySelector('[data-relay-action="save"]')!);
  const save = page.provider.deviceRuns.filter((run) => run.action === "saveRelay").at(-1) as {
    relay: Record<string, unknown>;
  };
  expect(save.relay).toEqual({
    id: "relay-1",
    name: "cmux TURN 2",
    urls: ["turns:turn.example.com:443?transport=tcp", "turn:turn.example.com:3478"],
    mode: "shared_secret",
    enabled: true,
    priority: 0,
  });
  expect("secret" in save.relay).toBe(false);
  page.unmount();
});

test("Check Relay sends checkRelay and shows the returned text; a relay without a secret cannot be checked", async () => {
  const page = await open();
  const row = (id: string) => card(page.container).querySelector<HTMLElement>(`[data-relay="${id}"]`)!;
  expect(row("relay-2").querySelector("[data-relay-off]")!.textContent).toBe("Off");
  expect(row("relay-2").querySelector<HTMLButtonElement>('[data-relay-action="check"]')!.disabled).toBe(true);
  expect(row("relay-1").querySelector("[data-relay-off]")).toBeNull();
  expect(row("relay-1").textContent).toContain("Shared secret");
  await click(row("relay-1").querySelector('[data-relay-action="check"]')!);
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "checkRelay", id: "relay-1" }]);
  expect(row("relay-1").querySelector("[data-relay-check]")!.textContent).toBe(
    "Reached turns:turn.example.com:443?transport=tcp in 38 ms (TURN allocation succeeded).",
  );
  page.unmount();
});

test("Delete asks for confirmation before it sends deleteRelay", async () => {
  const page = await open();
  const row = () => card(page.container).querySelector<HTMLElement>('[data-relay="relay-2"]');
  await click(row()!.querySelector('[data-relay-action="delete"]')!);
  expect(row()!.querySelector("[data-devices-confirm]")!.textContent).toContain("Delete this relay?");
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([]);
  await click(row()!.querySelector('[data-devices-confirm-action="confirm"]')!);
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "deleteRelay", id: "relay-2" }]);
  expect(row()).toBeNull();
  page.unmount();
});

test("the history table has the seven columns and a pill per event, colored by tone", async () => {
  const page = await open();
  const table = card(page.container).querySelector<HTMLTableElement>('[data-devices-group="history"] table')!;
  expect([...table.querySelectorAll("th")].map((th) => th.textContent)).toEqual([
    "Time",
    "Event",
    "Device",
    "Host",
    "Access",
    "Detail",
    "Duration",
  ]);
  const ended = table.querySelector<HTMLElement>('[data-history="h3"]')!;
  expect([...ended.querySelectorAll("td")].map((td) => td.textContent)).toEqual([
    "Oct 19, 2026 at 4:12 PM",
    "Ended",
    "Aziz's iPhone",
    "Studio Mac",
    "Full control",
    "",
    "22m 27s",
  ]);
  const pill = table.querySelector<HTMLElement>('[data-history="h1"] .devices-pill')!;
  expect(pill.dataset.tone).toBe("danger");
  expect(pill.dataset.event).toBe("denied");
  page.unmount();
});

test("a change from the host shows without a reload; Sign In shows when the host offers it", async () => {
  const page = await open();
  const state = mockDevicesState();
  await act(async () =>
    page.provider.setDevices({
      ...state,
      status: { text: "Not signed in", tone: "neutral" },
      signIn: "Sign In Again",
      error: "This Mac was removed from your devices.",
      thisDevice: null,
      sharing: null,
      others: [],
      history: [],
    }),
  );
  await settle();
  const element = card(page.container);
  expect(element.querySelector("[data-devices-status]")!.textContent).toBe("Not signed in");
  expect(element.querySelector("[data-devices-state-error]")!.textContent).toBe(
    "This Mac was removed from your devices.",
  );
  expect(element.querySelector('[data-devices-group="this"]')).toBeNull();
  expect(element.querySelector('[data-devices-group="sharing"]')).toBeNull();
  expect(element.querySelector('[data-devices-empty="others"]')!.textContent).toContain("No other devices yet");
  expect(element.querySelector('[data-devices-empty="history"]')!.textContent).toBe("No Mac Screen activity yet.");
  await click(element.querySelector('[data-devices-action="signIn"]')!);
  expect(nonRefresh(page.provider.deviceRuns)).toEqual([{ action: "signIn" }]);
  expect(card(page.container).querySelector('[data-devices-action="signIn"]')).toBeNull();
  page.unmount();
});

test("without a device hub the card shows only the status text", async () => {
  const page = await open();
  await act(async () =>
    page.provider.setDevices({ ...mockDevicesState(), available: false, status: { text: "Off", tone: "neutral" } }),
  );
  await settle();
  const element = card(page.container);
  expect(element.querySelector("[data-devices-status]")!.textContent).toBe("Off");
  expect(element.querySelector("[data-devices-group]")).toBeNull();
  expect(element.querySelector("button")).toBeNull();
  page.unmount();
});

test("a host without a devices provider draws nothing", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    mock: { failing: { "cmux.settings.devices.state": "cmux.page.unavailable" } },
  });
  await settle();
  expect(card(page.container).childElementCount).toBe(0);
  page.unmount();
});

test("a fingerprint shows the whole key on hover and Copy writes it", async () => {
  const page = await open();
  const self = card(page.container).querySelector<HTMLElement>(
    '[data-devices-group="this"] [data-device="dev-mac-studio"]',
  )!;
  const full = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809";
  expect(self.querySelector("[data-device-fingerprint] code")!.getAttribute("title")).toBe(full);
  await click(self.querySelector("[data-device-copy-fingerprint]")!);
  expect(page.provider.clipboard).toBe(full);
  page.unmount();
});

test("history fits its card: fixed columns, names wrap at word boundaries, full text on hover", async () => {
  const page = await open();
  const table = card(page.container).querySelector<HTMLElement>(".devices-history")!;
  expect(table.classList.contains("devices-history-fixed")).toBe(true);
  expect(table.querySelectorAll("colgroup col").length).toBe(7);
  const first = table.querySelector("tbody tr")!;
  for (const cell of first.querySelectorAll("td.devices-wrap"))
    expect(cell.getAttribute("title")).toBe(cell.textContent);
  page.unmount();
});

test("history cells wrap instead of widening the table", async () => {
  const page = await open();
  const table = card(page.container).querySelector<HTMLElement>(".devices-history")!;
  const first = table.querySelector("tbody tr")!;
  expect(first.querySelectorAll("td.devices-wrap").length).toBe(3);
  expect(first.querySelector("td.devices-time")).not.toBeNull();
  page.unmount();
});

test("device rows keep their status and Copy at a narrow width: their lines wrap", async () => {
  const page = await open();
  const rows = card(page.container).querySelectorAll<HTMLElement>("[data-device]");
  expect(rows.length).toBeGreaterThan(1);
  for (const row of rows) expect(row.classList.contains("devices-device")).toBe(true);
  page.unmount();
});
