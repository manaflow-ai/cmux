// Settings > MCP Servers, Claude Code and Codex (Labs labs.agentCustomization): the servers those
// agents start, from their own files. Off draws nothing; on lists each agent's servers with where
// each is set and what it runs, turns one on or off with its switch, removes one only after a second
// click, and adds one from the form. Each sends only the gesture clicked.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");
const { words } = await import("./components/AgentMcpServers");

const on = { setup: (provider: { agentMcp: { enabled: boolean } }) => void (provider.agentMcp.enabled = true) };
const group = (container: HTMLElement, agent: string) =>
  container.querySelector<HTMLElement>(`[data-agent-mcp-group="${agent}"]`);
const rows = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-agent-mcp]")].map((row) => row.dataset.agentMcp);

test("off (the default), the page shows only cmux's own servers", async () => {
  const page = await renderPage({ path: "/settings/mcpServers" });
  await settle();
  expect(page.container.querySelector('[data-card="mcpServers"]')).not.toBeNull();
  expect(page.container.querySelector("[data-agent-mcp]")).toBeNull();
  expect(page.provider.agentMcpRuns).toEqual([]);
  page.unmount();
});

test("on, Claude Code and Codex each list their servers under cmux's own", async () => {
  const page = await renderPage({ path: "/settings/mcpServers", ...on });
  await settle();
  const claude = group(page.container, "claude")!;
  const codex = group(page.container, "codex")!;
  expect(claude.querySelector(".group-title")!.textContent).toBe("Claude Code");
  expect(codex.querySelector(".group-title")!.textContent).toBe("Codex");
  expect(rows(claude)).toEqual(["claude:user:agent-memory", "claude:user:linear", "claude:project:playwright"]);
  expect(rows(codex)).toEqual(["codex:user:repo", "codex:user:openaiDeveloperDocs", "codex:plugin:codex_app"]);
  const repo = codex.querySelector<HTMLElement>('[data-agent-mcp="codex:user:repo"]')!;
  expect(repo.textContent).toContain("All folders");
  expect(repo.textContent).toContain("Env: REPO_TOKEN");
  expect(repo.textContent).toContain("/Users/me/bin/repo-tools mcp");
  expect(claude.querySelector('[data-agent-mcp="claude:project:playwright"] [data-agent-mcp-pending]')).not.toBeNull();
  // A plugin's server can be switched off, not removed.
  const plugin = codex.querySelector<HTMLElement>('[data-agent-mcp="codex:plugin:codex_app"]')!;
  expect(plugin.textContent).toContain("From plugin codex-app-tools@openai-bundled");
  expect(plugin.querySelector('[data-agent-mcp-action="remove"]')).toBeNull();
  expect(page.container.querySelector("[data-agent-mcp-folder]")!.textContent).toContain("/Users/me/src/app");
  page.unmount();
});

test("the switch turns one server off and on, and Remove needs a second click", async () => {
  const page = await renderPage({ path: "/settings/mcpServers", ...on });
  await settle();
  const press = async (selector: string) => {
    await act(async () => page.container.querySelector<HTMLElement>(selector)!.click());
    await settle();
  };
  await press('[data-agent-mcp="claude:user:agent-memory"] [data-agent-mcp-action="toggle"]');
  expect(page.provider.agentMcpRuns).toEqual([
    { action: "disable", agent: "claude", name: "agent-memory", scope: "user" },
  ]);
  expect(
    page.container.querySelector<HTMLElement>('[data-agent-mcp="claude:user:agent-memory"]')!.dataset.agentMcpEnabled,
  ).toBe("false");
  await press('[data-agent-mcp="claude:user:linear"] [data-agent-mcp-action="toggle"]');
  expect(page.provider.agentMcpRuns.at(-1)).toEqual({
    action: "enable",
    agent: "claude",
    name: "linear",
    scope: "user",
  });
  await press('[data-agent-mcp="codex:user:repo"] [data-agent-mcp-action="remove"]');
  expect(page.provider.agentMcpRuns).toHaveLength(2);
  expect(page.container.querySelector("[data-agent-mcp-confirm]")!.textContent).toContain(
    "/Users/me/.codex/config.toml",
  );
  await press('[data-agent-mcp-action="confirmRemove"]');
  expect(page.provider.agentMcpRuns.at(-1)).toEqual({ action: "remove", agent: "codex", name: "repo", scope: "user" });
  expect(page.container.querySelector('[data-agent-mcp="codex:user:repo"]')).toBeNull();
  page.unmount();
});

test("Add Server… writes a command server with its env, or a URL server", async () => {
  const page = await renderPage({ path: "/settings/mcpServers", ...on });
  await settle();
  const codex = group(page.container, "codex")!;
  await act(async () => codex.querySelector<HTMLElement>('[data-agent-mcp-action="add"]')!.click());
  await settle();
  const type = async (field: string, value: string) => {
    const input = codex.querySelector<HTMLInputElement | HTMLTextAreaElement>(`[data-agent-mcp-field="${field}"]`)!;
    await act(async () => {
      const proto = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
  };
  await type("name", "fs");
  await type("target", 'npx -y "@acme/fs server" --root .');
  await type("env", "FS_TOKEN=abc\n\nPLAIN=1");
  await act(async () => codex.querySelector<HTMLElement>('[data-agent-mcp-action="save"]')!.click());
  await settle();
  expect(page.provider.agentMcpRuns.at(-1)).toEqual({
    action: "add",
    agent: "codex",
    name: "fs",
    scope: "user",
    command: "npx",
    args: ["-y", "@acme/fs server", "--root", "."],
    env: ["FS_TOKEN=abc", "PLAIN=1"],
  });
  expect(rows(codex)).toContain("codex:user:fs");
  expect(codex.querySelector("[data-agent-mcp-add]")).toBeNull();
  page.unmount();
});

test("words keeps quoted words whole", () => {
  expect(words(`a "b c" 'd e' f`)).toEqual(["a", "b c", "d e", "f"]);
});
