// Settings > Integrations, its Connections tab (ConnectionsPanel inside IntegrationsHubCard): the
// hosted MCP catalog as a grid in the CLI's rank order beside the Approvals, Rules and Audit tabs.
// Connect sends the server and whose it is (the active team only when picked), a key-auth row's
// pasted key goes once and is cleared, Disconnect asks first, an unavailable row says why and has no
// button, and with no hub only the Connections tab shows.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, changeValue, fire } = await import("./testing");
const { mockHubOverview, mockHubState } = await import("./mockHub");

const path = "/settings/integrations";
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
  expect(tiles(page.container)).toEqual(["linear", "github", "sentry", "notion", "exa", "stripe", "figma"]);
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
  await click(tile(page.container, "github").querySelector('[data-connections-action="connect"]')!);
  expect(page.provider.connectionsRuns).toEqual([{ action: "connect", name: "github", owner: "me" }]);
  await changeValue(page.container.querySelector<HTMLSelectElement>("[data-connections-owner]")!, "team");
  await click(tile(page.container, "notion").querySelector('[data-connections-action="connect"]')!);
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
  expect(figma.querySelector("[data-connections-action]")).toBeNull();
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
  expect(tiles(page.container).length).toBe(7);
  page.unmount();
});
