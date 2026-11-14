// Agents > Agent integrations: optional help for coding-agent hooks. The card stays collapsed
// and reads nothing until opened; opened, it lists `cmux agent hook status` with Install, Repair
// or Remove by state, sends only the gesture clicked, and a file cmux did not create in the way
// offers no Install but says what is there and gives the command to run by hand.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { ops, renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="agentIntegrations"]')!;
const ids = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-integration]")].map((row) => row.dataset.integration);
const actions = (element: HTMLElement, id: string) =>
  [...element.querySelectorAll<HTMLElement>(`[data-integration="${id}"] [data-integration-action]`)].map(
    (button) => button.dataset.integrationAction,
  );

test("closed, the card reads and runs nothing", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container);
  expect(element.querySelector("details")!.open).toBe(false);
  expect(ops(page.provider, "cmux.settings.integrations.run")).toEqual([]);
  expect(ops(page.provider, "cmux.settings.integrations.state")).toEqual([]);
  expect(page.provider.integrationRuns).toEqual([]);
  page.unmount();
});

test("opened, it lists each agent's hooks with the gestures its state allows", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  await settle();
  const element = card(page.container);
  expect(element.querySelector("details")!.open).toBe(true);
  expect(ids(element)).toEqual(["claude", "codex", "amp", "gemini"]);
  expect(element.textContent).toContain("Claude Code");
  expect(actions(element, "claude")).toEqual(["remove"]);
  expect(actions(element, "codex")).toEqual(["repair", "remove"]);
  expect(actions(element, "gemini")).toEqual(["install"]);
  // A file cmux did not create: no Install, what is in the way, and the command to copy.
  expect(actions(element, "amp")).toEqual(["copy"]);
  const amp = element.querySelector<HTMLElement>('[data-integration="amp"]')!;
  expect(amp.querySelector("[data-integration-reason]")!.textContent).toBe(
    "A file cmux didn’t create is here. Move it first.",
  );
  expect(amp.textContent).toContain("~/.config/amp/plugins/cmux-tui-journal.ts");
  expect(amp.querySelector("[data-integration-command]")!.textContent).toBe("cmux agent hook install amp");
  // Opening only read status.
  expect(page.provider.integrationRuns).toEqual([]);
  page.unmount();
});

test("a click sends that gesture for that agent and shows the new state", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  await settle();
  const element = card(page.container);
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-integration="gemini"] [data-integration-action="install"]');
  await press('[data-integration="codex"] [data-integration-action="repair"]');
  await press('[data-integration="claude"] [data-integration-action="remove"]');
  expect(page.provider.integrationRuns).toEqual([
    { action: "install", id: "gemini" },
    { action: "repair", id: "codex" },
    { action: "remove", id: "claude" },
  ]);
  expect(element.querySelector<HTMLElement>('[data-integration="gemini"]')!.dataset.integrationState).toBe("installed");
  expect(actions(element, "claude")).toEqual(["install"]);
  await press('[data-integration="amp"] [data-integration-action="copy"]');
  expect(page.provider.clipboard).toBe("cmux agent hook install amp");
  page.unmount();
});

test("without the cmux CLI the card says so and still gives the command", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  page.provider.integrations = {
    loading: false,
    problem: "unavailable",
    command: "cmux agent hook install",
    providers: [],
  };
  await act(async () =>
    card(page.container).querySelector<HTMLButtonElement>('[data-integration-action="refresh"]')!.click(),
  );
  await settle();
  const element = card(page.container);
  expect(element.querySelector("[data-integrations-problem]")!.getAttribute("data-integrations-problem")).toBe(
    "unavailable",
  );
  expect(element.querySelector("[data-integrations-command]")!.textContent).toBe("cmux agent hook install");
  page.unmount();
});

test("the link rows come first, under Your other apps, with Connect, Reconnect and Disconnect", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  const link = (app: string, state: "installed" | "absent" | "partial" | "conflict", path: string) => ({
    id: `link-${app}`,
    path,
    state,
    reason: state === "conflict" ? ("not_owned" as const) : null,
    detail: null,
    error: null,
  });
  page.provider.integrations = {
    ...page.provider.integrations,
    providers: [
      { id: "claude", path: "~/.claude/settings.json", state: "installed", reason: null, detail: null, error: null },
      link("claude-desktop", "absent", "~/Library/Application Support/Claude/claude_desktop_config.json"),
      link("claude-code", "installed", "~/.claude.json"),
      link("codex", "partial", "~/.codex/config.toml"),
    ],
  };
  const element = card(page.container);
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-integration-action="refresh"]');
  const links = element.querySelector<HTMLElement>("[data-integrations-links]")!;
  expect(links.textContent).toContain("Your other apps");
  expect(ids(links)).toEqual(["link-claude-desktop", "link-claude-code", "link-codex"]);
  // The hooks stay below, in their own list.
  expect(ids(element)).toEqual(["link-claude-desktop", "link-claude-code", "link-codex", "claude"]);
  const row = (id: string) => element.querySelector<HTMLElement>(`[data-integration="${id}"]`)!;
  expect(row("link-claude-desktop").textContent).toContain("Claude desktop");
  expect(row("link-claude-desktop").textContent).toContain("Connect");
  expect(row("link-codex").textContent).toContain("Codex desktop and CLI");
  expect(row("link-codex").textContent).toContain("Reconnect");
  expect(row("link-claude-code").textContent).toContain("Connected");
  await press('[data-integration="link-claude-desktop"] [data-integration-action="install"]');
  expect(page.provider.integrationRuns).toEqual([{ action: "install", id: "link-claude-desktop" }]);
  expect(row("link-claude-desktop").dataset.integrationState).toBe("installed");
  page.unmount();
});

test("a cmux server another tool added is named, with no Connect and no command to copy", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.integrations" });
  page.provider.integrations = {
    ...page.provider.integrations,
    providers: [
      {
        id: "link-codex",
        path: "~/.codex/config.toml",
        state: "conflict",
        reason: "not_owned",
        detail: null,
        error: null,
      },
    ],
  };
  const element = card(page.container);
  await act(async () => element.querySelector<HTMLButtonElement>('[data-integration-action="refresh"]')!.click());
  await settle();
  expect(actions(element, "link-codex")).toEqual([]);
  const codex = element.querySelector<HTMLElement>('[data-integration="link-codex"]')!;
  expect(codex.querySelector("[data-integration-reason]")!.textContent).toContain("named cmux");
  expect(codex.querySelector("[data-integration-command]")).toBeNull();
  page.unmount();
});
