// Settings > Integrations, its Connections tab (ConnectionsPanel inside IntegrationsHubCard): the
// hosted MCP catalog as a grid in the CLI's rank order beside the Approvals, Rules and Audit tabs.
// Connect sends the server and whose it is (the active team only when picked), a key-auth row's
// pasted key goes once and is cleared, Disconnect asks first, an unavailable row says why and has no
// button, and with no hub only the Connections tab shows.
import { afterAll, expect, test, beforeAll } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, changeValue, fire } = await import("./testing");
const { mockHubOverview, mockHubState } = await import("./mockHub");
const { ensureConnectionsUpcomingLabRow } = await import("./mockConnections");
beforeAll(() => ensureConnectionsUpcomingLabRow());

const path = "/settings/integrations";
/** The top five in rank order, then the rest a person can see with the Labs toggle off. */
const TOP_AND_MORE = ["linear", "sentry", "atlassian", "notion", "vercel", "github", "exa", "figma"];
const UPCOMING = ["slack", "gmail", "google-calendar", "google-drive"];
const noApprovals = (provider: { hub: unknown }) =>
  void (provider.hub = mockHubState(mockHubOverview({ approvals: [] })));
const tabs = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("[data-hub-tab]")].map((tab) => tab.dataset.hubTab);
const tiles = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("[data-connections-entry]")].map((tile) => tile.dataset.connectionsEntry);
const tile = (container: HTMLElement, name: string) =>
  container.querySelector<HTMLElement>(`[data-connections-entry="${name}"]`)!;
const openConnections = async (container: HTMLElement) => {
  await click(container.querySelector('[data-hub-tab="connections"]')!);
  await settle();
};

test("a waiting call opens Approvals; Connections holds the grid in rank order beside the hub's accounts", async () => {
  const page = await renderPage({ path });
  await settle();
  expect(tabs(page.container)).toEqual(["connections", "approvals", "rules", "audit"]);
  expect(page.container.querySelector('[data-hub-panel="approvals"]')).not.toBeNull();
  expect(page.container.querySelector("[data-connections-entry]")).toBeNull();
  await openConnections(page.container);
  expect(tiles(page.container)).toEqual(TOP_AND_MORE);
  expect(tile(page.container, "linear").textContent).toContain("Connected · 23 tools");
  expect(tile(page.container, "linear").textContent).toContain("Team");
  expect(page.container.querySelector('[data-hub-group="accounts"]')).not.toBeNull();
  expect(page.provider.connectionsRuns).toEqual([]);
  page.unmount();
});

test("with nothing waiting it opens on Connections; Rules and Audit are a click away", async () => {
  const page = await renderPage({
    path,
    setup: (provider) => void (provider.hub = mockHubState(mockHubOverview({ approvals: [] }))),
  });
  await settle();
  expect(tiles(page.container).length).toBeGreaterThan(0);
  await click(page.container.querySelector('[data-hub-tab="rules"]')!);
  expect(page.container.querySelector('[data-hub-group="rules"]')).not.toBeNull();
  expect(page.container.querySelector("[data-connections-entry]")).toBeNull();
  await click(page.container.querySelector('[data-hub-tab="audit"]')!);
  expect(page.container.querySelector('[data-hub-group="audit"]')).not.toBeNull();
  page.unmount();
});

test("Connect sends the server as yours, or the active team's once the team is picked", async () => {
  const page = await renderPage({ path });
  await settle();
  await openConnections(page.container);
  await click(tile(page.container, "github").querySelector('[data-connect-action="connect"]')!);
  expect(page.provider.connectionsRuns).toEqual([{ action: "connect", name: "github", owner: "me" }]);
  await changeValue(page.container.querySelector<HTMLSelectElement>("[data-connections-owner]")!, "team");
  await click(tile(page.container, "notion").querySelector('[data-connect-action="connect"]')!);
  expect(page.provider.connectionsRuns[1]).toEqual({
    action: "connect",
    name: "notion",
    owner: "team",
    team: "team-personal",
  });
  page.unmount();
});

test("a key-auth row sends its pasted key once and clears the field", async () => {
  const page = await renderPage({
    path,
    setup: (provider) => void (provider.hub = mockHubState(mockHubOverview({ approvals: [] }))),
  });
  await settle();
  const exa = tile(page.container, "exa");
  const field = exa.querySelector<HTMLInputElement>("[data-connections-key-field]")!;
  expect(field.type).toBe("password");
  await changeValue(field, "exa-test-key");
  await fire(exa.querySelector("form")!, "submit");
  expect(page.provider.connectionsRuns).toEqual([{ action: "connect", name: "exa", owner: "me", key: "exa-test-key" }]);
  expect(tile(page.container, "exa").textContent).toContain("Connected");
  expect(JSON.stringify(page.container.innerHTML)).not.toContain("exa-test-key");
  page.unmount();
});

test("Disconnect asks first, and Cancel sends nothing", async () => {
  const page = await renderPage({
    path,
    setup: (provider) => void (provider.hub = mockHubState(mockHubOverview({ approvals: [] }))),
  });
  await settle();
  const sentry = () => tile(page.container, "sentry");
  await click(sentry().querySelector('[data-connections-action="remove"]')!);
  expect(sentry().querySelector("[data-connections-confirm]")).not.toBeNull();
  await click(sentry().querySelector('[data-connections-action="cancel"]')!);
  expect(page.provider.connectionsRuns).toEqual([]);
  await click(sentry().querySelector('[data-connections-action="remove"]')!);
  await click(sentry().querySelector('[data-connections-action="confirmRemove"]')!);
  expect(page.provider.connectionsRuns).toEqual([{ action: "remove", id: "mcs_mock_sentry" }]);
  expect(sentry().dataset.connectionsState).toBe("connect");
  page.unmount();
});

test("an unavailable row says why in one line and has no button", async () => {
  const page = await renderPage({
    path,
    setup: (provider) => void (provider.hub = mockHubState(mockHubOverview({ approvals: [] }))),
  });
  await settle();
  const figma = tile(page.container, "figma");
  expect(figma.dataset.connectionsState).toBe("unavailable");
  expect(figma.querySelector("[data-connections-why]")!.textContent).toBe("Not set up on this deployment yet.");
  expect(figma.querySelector("[data-connections-action], [data-connect-action]")).toBeNull();
  page.unmount();
});

test("Slack and Google list as Not set up only with labs.connectionsUpcoming on", async () => {
  const off = await renderPage({ path, setup: noApprovals });
  await settle();
  expect(tiles(off.container)).toEqual(TOP_AND_MORE);
  off.unmount();
  const on = await renderPage({ path, setup: noApprovals, mock: { values: { "labs.connectionsUpcoming": true } } });
  await settle();
  expect(tiles(on.container)).toEqual([...TOP_AND_MORE, ...UPCOMING]);
  const slack = tile(on.container, "slack");
  expect(slack.dataset.connectionsState).toBe("unavailable");
  expect(slack.dataset.connectionsUpcoming).toBe("");
  expect(slack.querySelector("[data-connections-why]")!.textContent).toBe("Not set up on this deployment yet.");
  expect(slack.querySelector("[data-connections-action]")).toBeNull();
  on.unmount();
});

test("Vercel connects in one tap like the rest; its tile is marked as signing in back to this Mac", async () => {
  const page = await renderPage({ path, setup: noApprovals });
  await settle();
  const vercel = () => tile(page.container, "vercel");
  expect(vercel().dataset.connectionsLoopback).toBe("");
  expect(tile(page.container, "linear").dataset.connectionsLoopback).toBeUndefined();
  await click(vercel().querySelector('[data-connect-action="connect"]')!);
  expect(page.provider.connectionsRuns).toEqual([{ action: "connect", name: "vercel", owner: "me" }]);
  expect(vercel().dataset.connectionsState).toBe("connected");
  page.unmount();
});

test("with no hub on this deployment only the Connections tab shows", async () => {
  const page = await renderPage({
    path,
    setup: (provider) =>
      void (provider.hub = { loading: false, problem: "unavailable", overview: null, error: null, lastCall: null }),
  });
  await settle();
  expect(tabs(page.container)).toEqual(["connections"]);
  expect(tiles(page.container)).toEqual(TOP_AND_MORE);
  page.unmount();
});

test("a connected tile whose sign-in lapses soon says when and offers Reconnect; a lapsed one asks to sign in again", async () => {
  const { mockConnectionsState, mockExpiringCatalog } = await import("./mockConnections");
  const page = await renderPage({
    path,
    setup: (provider) => {
      provider.hub = mockHubState(mockHubOverview({ approvals: [] }));
      provider.connections = mockConnectionsState(mockExpiringCatalog());
    },
  });
  await settle();
  const linear = tile(page.container, "linear");
  expect(linear.dataset.connectionsState).toBe("connected");
  expect(linear.querySelector<HTMLElement>(".connect-pill")!.dataset.connectPill).toBe("expiring");
  expect(linear.querySelector<HTMLElement>("[data-connections-expiry]")!.textContent).toContain(
    "Reconnect to keep it working",
  );
  const sentry = tile(page.container, "sentry");
  expect(sentry.querySelector<HTMLElement>(".connect-pill")!.dataset.connectPill).toBe("reauth");
  // A connection that does not lapse soon offers no Reconnect, only Disconnect.
  expect(tile(page.container, "github").querySelector('[data-connect-action="reconnect"]')).toBeNull();
  await click(linear.querySelector('[data-connect-action="reconnect"]')!);
  expect(page.provider.connectionsRuns).toEqual([{ action: "reconnect", id: "mcs_mock_linear" }]);
  expect(linear.querySelector('[data-connections-action="remove"]')).not.toBeNull();
  page.unmount();
});

test("All connections lists the accounts, the model accounts and the connected apps, each with one action", async () => {
  const page = await renderPage({
    path,
    setup: (provider) => void (provider.hub = mockHubState(mockHubOverview({ approvals: [] }))),
  });
  await settle();
  const list = page.container.querySelector<HTMLElement>("[data-all-connections]")!;
  const rows = [...list.querySelectorAll<HTMLElement>("[data-all-connections-row]")];
  // cmux and Codex from the accounts (OpenRouter has nothing found, so it is not a connection yet),
  // then the two connected apps in rank order; none of them counts as a catalog tile.
  expect(rows.map((row) => row.dataset.allConnectionsRow)).toEqual([
    "cmux",
    "model:chatGPT:codex",
    "app:linear",
    "app:sentry",
  ]);
  expect(rows.map((row) => row.dataset.allConnectionsKind)).toEqual(["account", "model", "app", "app"]);
  for (const row of rows) expect(row.querySelectorAll("button").length).toBe(1);
  expect(rows[2]!.textContent).toContain("Connected · 23 tools");
  expect(tiles(page.container)).toEqual(TOP_AND_MORE);
  // A model row only links to where it is managed.
  await click(rows[1]!.querySelector('[data-all-connections-action="manage"]')!);
  await settle();
  expect(page.container.querySelector('[data-section="accounts"]')).not.toBeNull();
  page.unmount();
});

test("All connections' Reconnect runs on the app row itself", async () => {
  const { mockConnectionsState, mockExpiringCatalog } = await import("./mockConnections");
  const page = await renderPage({
    path,
    setup: (provider) => {
      provider.hub = mockHubState(mockHubOverview({ approvals: [] }));
      provider.connections = mockConnectionsState(mockExpiringCatalog());
    },
  });
  await settle();
  const row = page.container.querySelector<HTMLElement>('[data-all-connections-row="app:sentry"]')!;
  expect(row.querySelector<HTMLElement>(".connect-pill")!.dataset.connectPill).toBe("reauth");
  await click(row.querySelector('[data-all-connections-action="reconnect"]')!);
  expect(page.provider.connectionsRuns).toEqual([{ action: "reconnect", id: "mcs_mock_sentry" }]);
  page.unmount();
});

test("GitHub is one All connections row, folding the integration's accounts and the GitHub sign-ins", async () => {
  const { allConnectionRows } = await import("./components/AllConnections");
  const { mockCmuxAccount } = await import("./mockProvider");
  const signIn = (family: "github" | "claude", name: string, signedIn: boolean) =>
    ({ id: `${family}-${name}`, family, name, email: null, signedIn }) as never;
  const accounts = {
    cmux: mockCmuxAccount.signedIn,
    github: { connections: [{ account: "sample-team" }] },
    signInAccounts: [signIn("github", "octocat", true), signIn("claude", "me", false)],
    groups: [],
  } as never;
  const rows = allConnectionRows(accounts, [], null);
  expect(rows.map((row) => row.id)).toEqual(["cmux", "github", "signin:claude:claude-me"]);
  expect(rows[1]).toMatchObject({ detail: "octocat, sample-team", status: "connected", action: { to: "accounts" } });
  expect(rows[2]).toMatchObject({ kind: "model", status: "reauth", action: { to: "models" } });
  // A GitHub sign-in alone still gets the one row; signed out, it asks to sign in again.
  const alone = allConnectionRows(
    { ...(accounts as object), github: null, signInAccounts: [signIn("github", "octocat", false)] } as never,
    [],
    null,
  );
  expect(alone.filter((row) => row.family === "github")).toMatchObject([{ status: "reauth" }]);
});
