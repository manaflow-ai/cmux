// Settings > MCP Servers: the services the person connected for their agents. The page lists each
// with who has it and whether it works, offers Sign In only where a sign-in can help, removes a
// server only after a second click, and sends only the gesture clicked.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="mcpServers"]')!;
const names = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-mcp-server]")].map((row) => row.dataset.mcpServer);
const actions = (element: HTMLElement, name: string) =>
  [...element.querySelectorAll<HTMLElement>(`[data-mcp-server="${name}"] [data-mcp-action]`)].map(
    (button) => button.dataset.mcpAction,
  );

test("it lists each saved server with its state, who has it, and the gestures that help", async () => {
  const page = await renderPage({ path: "/settings/mcpServers" });
  await settle();
  const element = card(page.container);
  expect(names(element)).toEqual(["linear", "slack", "notes"]);
  const linear = element.querySelector<HTMLElement>('[data-mcp-server="linear"]')!;
  expect(linear.textContent).toContain("Linear");
  expect(linear.textContent).toContain("linear.app");
  expect(linear.textContent).toContain("All agents");
  expect(linear.textContent).toContain("23 tools");
  expect(linear.textContent).toContain("Connected");
  // Connected: nothing to sign in to. Needs sign-in: Sign In. A local command: no sign-in.
  expect(actions(element, "linear")).toEqual(["remove"]);
  expect(actions(element, "slack")).toEqual(["signin", "remove"]);
  expect(actions(element, "notes")).toEqual(["remove"]);
  expect(element.querySelector('[data-mcp-server="notes"] [data-mcp-problem]')!.textContent).toBe(
    "the command exited with status 1",
  );
  // No internal names on the page.
  expect(element.textContent).not.toMatch(/acpmux|optchat/i);
  expect(page.provider.mcpServerRuns).toEqual([]);
  page.unmount();
});

test("the page says how to connect a service and has the switch for new chats", async () => {
  const page = await renderPage({ path: "/settings/mcpServers" });
  await settle();
  expect(card(page.container).querySelector("[data-mcp-connect-how]")!.textContent).toBe(
    "To add one, ask an agent in a chat; you approve it there.",
  );
  const toggle = page.container.querySelector<HTMLElement>('[data-row-key="agents.mcpServers.enabled"]');
  expect(toggle).not.toBeNull();
  expect(toggle!.textContent).toContain("Saved Servers in Agent Chats");
  page.unmount();
});

test("Sign In starts that server's sign-in and the row waits for the person", async () => {
  const page = await renderPage({ path: "/settings/mcpServers" });
  await settle();
  const element = card(page.container);
  await act(async () =>
    element.querySelector<HTMLButtonElement>('[data-mcp-server="slack"] [data-mcp-action="signin"]')!.click(),
  );
  await settle();
  expect(page.provider.mcpServerRuns).toEqual([{ action: "signin", name: "slack" }]);
  const slack = element.querySelector<HTMLElement>('[data-mcp-server="slack"]')!;
  expect(slack.dataset.mcpState).toBe("signingIn");
  expect(slack.querySelector("[data-mcp-waiting]")).not.toBeNull();
  expect(slack.querySelector('[data-mcp-action="signin"]')!.textContent).toBe("Open Sign-In Page");
  page.unmount();
});

test("Remove asks once more, and only the second click removes it", async () => {
  const page = await renderPage({ path: "/settings/mcpServers" });
  await settle();
  const element = card(page.container);
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-mcp-server="linear"] [data-mcp-action="remove"]');
  expect(page.provider.mcpServerRuns).toEqual([]);
  expect(element.querySelector('[data-mcp-server="linear"] [data-mcp-confirm]')!.textContent).toContain(
    "Remove Linear?",
  );
  await press('[data-mcp-server="linear"] [data-mcp-action="cancel"]');
  expect(page.provider.mcpServerRuns).toEqual([]);
  await press('[data-mcp-server="linear"] [data-mcp-action="remove"]');
  await press('[data-mcp-server="linear"] [data-mcp-action="confirmRemove"]');
  expect(page.provider.mcpServerRuns).toEqual([{ action: "remove", name: "linear" }]);
  expect(names(element)).toEqual(["slack", "notes"]);
  page.unmount();
});

test("with no server the page says how to connect one", async () => {
  const page = await renderPage({ path: "/settings/mcpServers" });
  page.provider.mcpServers = { loading: false, problem: null, servers: [] };
  await act(async () => card(page.container).querySelector<HTMLButtonElement>('[data-mcp-action="refresh"]')!.click());
  await settle();
  expect(card(page.container).querySelector("[data-mcp-empty]")!.textContent).toContain(
    "Approve one when an agent asks",
  );
  page.unmount();
});
