// Settings > Agents > Claude Code & Codex > Hooks (Labs labs.agentCustomization): every Claude Code and
// Codex hook with its event, matcher, command and whether it runs; Turn Off / Turn On and Remove only
// on the person's own hooks, cmux's own read-only, and nothing at all while the Labs switch is off.
// The page is Settings > Agents, where the layout places the card (page-layout.json, agents trail).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");
const { AGENT_CUSTOMIZATION_LAB } = await import("./components/AgentCustomizationCard");

const path = "/settings/agents";
const on = { path, mock: { values: { [AGENT_CUSTOMIZATION_LAB]: true } } };
const section = (container: HTMLElement) =>
  container.querySelector<HTMLElement>('[data-agent-customization-section="hooks"]');

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="agentCustomization"]');
const ids = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-agent-hook]")].map((row) => row.dataset.agentHook);
const actions = (element: HTMLElement, id: string) =>
  [...element.querySelectorAll<HTMLElement>(`[data-agent-hook="${id}"] [data-hook-action]`)].map(
    (button) => button.dataset.hookAction,
  );
const click = async (element: Element) => {
  await act(async () => {
    (element as HTMLElement).click();
  });
  await settle();
};

test("it lists every hook with its agent, event, matcher and command; cmux's own are read-only", async () => {
  const page = await renderPage(on);
  await settle();
  const element = card(page.container)!;
  expect(element).not.toBeNull();
  expect(ids(element)).toEqual([
    "claude-0a1b2c3d4e",
    "claude-1a1b2c3d4e",
    "claude-2a1b2c3d4e",
    "codex-3a1b2c3d4e",
    "codex-4a1b2c3d4e",
  ]);
  const guard = element.querySelector<HTMLElement>('[data-agent-hook="claude-0a1b2c3d4e"]')!;
  expect(guard.textContent).toContain("PreToolUse");
  expect(guard.textContent).toContain("Bash");
  expect(guard.textContent).toContain("bash ~/.claude/hooks/guard.sh");
  expect(guard.textContent).toContain("Claude Code");
  // The row is a group named by its event and command, and the command is visible text.
  expect(guard.getAttribute("role")).toBe("group");
  const named = guard
    .getAttribute("aria-labelledby")!
    .split(" ")
    .map((id) => document.getElementById(id)?.textContent);
  expect(named.join(" ")).toContain("bash ~/.claude/hooks/guard.sh");
  expect(guard.querySelector("[data-hook-command]")!.textContent).toBe("bash ~/.claude/hooks/guard.sh");
  expect(element.querySelector("[data-hook-counts]")!.textContent).toContain("3");
  expect(actions(element, "claude-0a1b2c3d4e")).toEqual(["disable", "remove"]);
  expect(actions(element, "claude-1a1b2c3d4e")).toEqual(["enable", "remove"]);
  // cmux's own hook: shown, labelled, no gestures.
  expect(actions(element, "claude-2a1b2c3d4e")).toEqual([]);
  expect(element.querySelector('[data-agent-hook="claude-2a1b2c3d4e"]')!.textContent).toContain("cmux");
  // A Codex hook it never approved says so.
  expect(element.querySelector('[data-agent-hook="codex-4a1b2c3d4e"]')!.textContent).toMatch(/not approved/i);
  expect(page.provider.agentHookRuns).toEqual([]);
  page.unmount();
});

test("Turn Off, Turn On, and Remove after a second click send exactly the gesture clicked", async () => {
  const page = await renderPage(on);
  await settle();
  const element = card(page.container)!;
  await click(element.querySelector('[data-agent-hook="claude-0a1b2c3d4e"] [data-hook-action="disable"]')!);
  expect(page.provider.agentHookRuns).toEqual([{ action: "disable", id: "claude-0a1b2c3d4e" }]);
  expect(element.querySelector<HTMLElement>('[data-agent-hook="claude-0a1b2c3d4e"]')!.dataset.hookEnabled).toBe(
    "false",
  );
  await click(element.querySelector('[data-agent-hook="claude-0a1b2c3d4e"] [data-hook-action="enable"]')!);
  await click(element.querySelector('[data-agent-hook="codex-4a1b2c3d4e"] [data-hook-action="remove"]')!);
  // The first click only asks.
  expect(page.provider.agentHookRuns).toHaveLength(2);
  await click(element.querySelector('[data-agent-hook="codex-4a1b2c3d4e"] [data-hook-action="confirmRemove"]')!);
  expect(page.provider.agentHookRuns.at(-1)).toEqual({ action: "remove", id: "codex-4a1b2c3d4e" });
  expect(ids(element)).not.toContain("codex-4a1b2c3d4e");
  page.unmount();
});

test("the agent filter shows one agent's hooks", async () => {
  const page = await renderPage(on);
  await settle();
  const element = card(page.container)!;
  await click(element.querySelector('[data-hook-filter="codex"]')!);
  expect(ids(element)).toEqual(["codex-3a1b2c3d4e", "codex-4a1b2c3d4e"]);
  page.unmount();
});

test("with the Labs switch off the card draws nothing and asks the app for no hooks", async () => {
  const page = await renderPage({ path });
  await settle();
  expect(card(page.container)).toBeNull();
  expect(page.provider.log.some((call) => call.op === "cmux.settings.agentHooks.state")).toBe(false);
  page.unmount();
});

test("with the lab on but no hooks CLI in the app, the Hooks section draws nothing", async () => {
  const page = await renderPage({
    ...on,
    setup: (provider) => (provider.agentHooks = { available: false }),
  });
  await settle();
  expect(card(page.container)).not.toBeNull();
  expect(section(page.container)).toBeNull();
  page.unmount();
});
