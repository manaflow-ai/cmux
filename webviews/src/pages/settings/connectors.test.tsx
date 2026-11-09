// Settings > Accounts and Devices > Connectors: what the person connected (attention first), then what
// they can connect; nothing connects without a click; on a team Connect asks who may use it, Only You
// checked; Disconnect asks first; a provider this server cannot connect says so and offers nothing; a
// server without connector management (production until it is switched on) says Connectors are not available.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { connectorRows } = await import("./connectors");
const { mockConnectors } = await import("./mockProvider");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="connectors"]')!;
const button = (selector: string) => card().querySelector<HTMLButtonElement>(selector)!;

async function open(setup?: (provider: MockSettingsProvider) => void) {
  page = await renderPage({ path: "/settings/connectors", setup });
  await settle();
  return page;
}

test("rows: connections needing attention first; Available leaves out only a working connection of the person's own", () => {
  const rows = connectorRows(mockConnectors());
  expect(rows.connected.map((row) => [row.provider, row.status, row.sharing])).toEqual([
    ["linear", "needs_reauth", "private"],
    ["github", "active", "team"],
  ]);
  // Linear needs signing in again, so it offers Connect again; GitHub works, so it does not.
  expect(rows.available.map((row) => [row.provider, row.configured])).toEqual([
    ["google-drive", false],
    ["linear", true],
    ["slack", true],
    ["gmail", true],
    ["google-calendar", true],
  ]);
  expect(connectorRows(null)).toEqual({ connected: [], available: [] });
});

test("the card draws each connection's account and who may use it", async () => {
  await open();
  const github = card().querySelector<HTMLElement>('[data-connection="conn_aaaaaaaaaaaaaaaaaaaa"]')!;
  expect(github.querySelector("[data-connection-detail]")!.textContent).toBe("acme-labs · Your team");
  const linear = card().querySelector<HTMLElement>('[data-connection="conn_bbbbbbbbbbbbbbbbbbbb"]')!;
  expect(linear.querySelector("[data-connection-detail]")!.textContent).toBe("Acme · Only you · Sign in again");
  // Google Drive cannot be connected on this server: no button, one line.
  expect(card().querySelector('[data-connector="google-drive"] [data-connector-action]')).toBeNull();
  expect(card().querySelector('[data-connector="google-drive"] [data-connector-unconfigured]')).not.toBeNull();
  expect(page!.provider.connectorRuns).toEqual([]);
});

test("on a team, Connect asks who may use it, Only You first, and connects as chosen", async () => {
  await open();
  await click(button('[data-connector="slack"] [data-connector-action="connect"]'));
  await settle();
  const choice = card().querySelector<HTMLElement>("[data-connector-sharing]")!;
  const radios = [...choice.querySelectorAll<HTMLInputElement>('input[type="radio"]')];
  expect(radios.map((radio) => [radio.value, radio.checked])).toEqual([
    ["private", true],
    ["team", false],
  ]);
  await click(radios[1]!);
  await click(button('[data-connector-action="confirmConnect"]'));
  await settle();
  expect(page!.provider.connectorRuns).toEqual([{ action: "connect", provider: "slack", sharing: "team" }]);
  // The new connection waits for approval in the browser, and the card says where to finish.
  expect(card().querySelector('[data-connector="slack"][data-connection-status="pending"]')).not.toBeNull();
  expect(card().querySelector("[data-connectors-opened]")).not.toBeNull();
});

test("with no team, Connect goes straight to the provider as Only You", async () => {
  await open((provider) => {
    provider.connectorsState = { ...mockConnectors(), team: null };
  });
  await click(button('[data-connector="gmail"] [data-connector-action="connect"]'));
  await settle();
  expect(card().querySelector("[data-connector-sharing]")).toBeNull();
  expect(page!.provider.connectorRuns).toEqual([{ action: "connect", provider: "gmail", sharing: "private" }]);
});

test("Disconnect asks first, then removes the connection", async () => {
  await open();
  await click(button('[data-connection="conn_aaaaaaaaaaaaaaaaaaaa"] [data-connector-action="disconnect"]'));
  await settle();
  expect(page!.provider.connectorRuns).toEqual([]);
  expect(card().querySelector("[data-connector-confirm]")).not.toBeNull();
  await click(button('[data-connection="conn_aaaaaaaaaaaaaaaaaaaa"] [data-connector-action="confirmDisconnect"]'));
  await settle();
  expect(page!.provider.connectorRuns).toEqual([
    { action: "disconnect", provider: "github", connection: "conn_aaaaaaaaaaaaaaaaaaaa" },
  ]);
  expect(card().querySelector('[data-connection="conn_aaaaaaaaaaaaaaaaaaaa"]')).toBeNull();
  // GitHub is connectable again.
  expect(card().querySelector('[data-connector="github"] [data-connector-action="connect"]')).not.toBeNull();
});

test("signed out, the card says where to sign in and lists nothing", async () => {
  await open((provider) => {
    provider.connectorsState = { available: true, signedIn: false };
  });
  expect(card().querySelector("[data-connectors-message]")!.textContent).toContain("Sign in");
  expect(card().querySelector("[data-connector]")).toBeNull();
});

test("a server without connector management (its older list, or a 400/404) says not available and offers nothing", async () => {
  const older = {
    available: true,
    signedIn: true,
    team: "team_1",
    connectors: [
      { provider: "github", state: "available" },
      { provider: "google-drive", state: "unavailable" },
    ],
  };
  for (const state of [older, { available: true, signedIn: true, status: 400, error: "team required" }]) {
    await open((provider) => {
      provider.connectorsState = state;
    });
    expect(card().querySelector("[data-connectors-message]")!.textContent).toContain("aren’t available");
    expect(card().querySelector("[data-connector]")).toBeNull();
    page!.unmount();
    page = null;
  }
  // Any other refusal is shown as it came.
  await open((provider) => {
    provider.connectorsState = { available: true, signedIn: true, status: 502, error: "HTTP 502" };
  });
  expect(card().querySelector("[data-connectors-message]")!.textContent).toBe("HTTP 502");
});
