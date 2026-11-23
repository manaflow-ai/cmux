// Settings > Agents > Claude Code & Codex (labs.agentCustomization). Off by default, the card draws
// nothing; on, it lists each agent's curated settings with the scope each comes from, sends exactly
// the change the person made and shows the value after it, never shows a masked secret, and Open
// File sends that file's path.
import { act } from "react";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderCard, settle } = await import("./testing");
const { AgentCustomizationCard } = await import("./components/AgentCustomizationCard");
const { ensureAgentCustomizationLabRow, MASK, MOCK_SECRET } = await import("./mockAgentConfig");
const { AGENT_CUSTOMIZATION_LAB } = await import("./agentConfig");

beforeAll(() => ensureAgentCustomizationLabRow());

const on = { mock: { values: { [AGENT_CUSTOMIZATION_LAB]: true } } };
const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="agentCustomization"]');
const agent = (container: HTMLElement, name: string) =>
  container.querySelector<HTMLElement>(`[data-agent-config="${name}"]`)!;
const setting = (container: HTMLElement, name: string, key: string) =>
  agent(container, name).querySelector<HTMLElement>(`[data-agent-setting="${key}"]`)!;
const click = async (element: Element) => {
  await act(async () => (element as HTMLElement).click());
  await settle();
};

test("off by default the card draws nothing and reads nothing", async () => {
  const page = await renderCard(<AgentCustomizationCard />);
  expect(card(page.container)).toBeNull();
  expect(page.container.textContent).toBe("");
  expect(page.provider.log.some((call) => call.op === "cmux.settings.agentConfig")).toBe(false);
  page.unmount();
});

test("with the lab on it lists each agent's curated settings and where each comes from", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  const element = card(page.container)!;
  expect(element).not.toBeNull();
  expect(element.querySelector("h3")!.textContent).toBe("Claude Code & Codex");
  const section = element.querySelector<HTMLElement>('[data-agent-section="settings"]')!;
  expect(Number(section.dataset.renderMs)).toBeGreaterThanOrEqual(0);
  const keys = (name: string) =>
    [...agent(page.container, name).querySelectorAll<HTMLElement>("[data-agent-setting]")].map(
      (row) => row.dataset.agentSetting,
    );
  expect(keys("claude")).toEqual(["model", "permissions.defaultMode", "cleanupPeriodDays"]);
  expect(keys("codex")).toEqual(["model", "model_reasoning_effort", "approval_policy", "sandbox_mode"]);
  const badge = (row: HTMLElement) => row.querySelector<HTMLElement>("[data-agent-scope]")!.textContent;
  expect(badge(setting(page.container, "claude", "model"))).toBe("Project");
  expect(badge(setting(page.container, "claude", "permissions.defaultMode"))).toBe("Local");
  expect(badge(setting(page.container, "claude", "cleanupPeriodDays"))).toBe("Default");
  expect(badge(setting(page.container, "codex", "model"))).toBe("User");
  // The scope picker offers only the writable scopes, User first.
  const scopes = [
    ...setting(page.container, "codex", "model").querySelectorAll<HTMLOptionElement>(
      "[data-agent-scope-picker] option",
    ),
  ].map((option) => option.textContent);
  expect(scopes).toEqual(["User", "Project", "Profile fast"]);
  expect(agent(page.container, "claude").querySelector("[data-agent-count]")!.textContent).toBe("7 of 8 keys shown");
  expect(agent(page.container, "codex").querySelector('[data-agent-profile="fast"]')).not.toBeNull();
  expect(agent(page.container, "codex").textContent).toContain("there is no saved active profile");
  // Files: the managed one is read only and not there; Open File only where the file exists.
  const managed = agent(page.container, "claude").querySelector<HTMLElement>('[data-agent-file="managed"]')!;
  expect(managed.textContent).toContain("Not created yet");
  expect(managed.textContent).toContain("Read Only");
  expect(managed.querySelector<HTMLButtonElement>('[data-agent-action="open"]')!.disabled).toBe(true);
  // Only gets so far: nothing was written.
  expect(page.provider.agentConfigRuns).toEqual([]);
  page.unmount();
});

test("a Claude Code answer with no profiles list renders its settings, not an error", async () => {
  const page = await renderCard(<AgentCustomizationCard />, {
    ...on,
    setup: (provider) => {
      // An older cmux sent `profiles` only for Codex.
      delete provider.agentConfig.claude.profiles;
    },
  });
  expect(page.container.textContent).not.toContain("Something went wrong");
  expect(setting(page.container, "claude", "model")).not.toBeNull();
  expect(agent(page.container, "claude").querySelector("[data-agent-profiles]")).toBeNull();
  expect(agent(page.container, "codex").querySelector('[data-agent-profile="fast"]')).not.toBeNull();
  page.unmount();
});

test("a pick sends exactly one set and the row shows the new value and scope", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  const row = setting(page.container, "codex", "model_reasoning_effort");
  await changeValue(row.querySelector<HTMLSelectElement>("select[data-agent-value]")!, "low");
  expect(page.provider.agentConfigRuns).toEqual([
    { verb: "set", agent: "codex", key: "model_reasoning_effort", value: "low", scope: "user" },
  ]);
  const after = setting(page.container, "codex", "model_reasoning_effort");
  expect(after.querySelector<HTMLSelectElement>("select[data-agent-value]")!.value).toBe("low");
  expect(after.querySelector("[data-agent-scope]")!.textContent).toBe("User");
  page.unmount();
});

test("a text is saved in the picked scope, and Use Default unsets the scope it comes from", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  const row = setting(page.container, "claude", "cleanupPeriodDays");
  await changeValue(row.querySelector<HTMLSelectElement>("[data-agent-scope-picker]")!, "local");
  await changeValue(row.querySelector<HTMLInputElement>("input[data-agent-value]")!, "90");
  expect(page.provider.agentConfigRuns).toEqual([]);
  await click(row.querySelector('[data-agent-action="save"]')!);
  expect(page.provider.agentConfigRuns).toEqual([
    { verb: "set", agent: "claude", key: "cleanupPeriodDays", value: "90", scope: "local" },
  ]);
  const saved = setting(page.container, "claude", "cleanupPeriodDays");
  expect(saved.querySelector<HTMLInputElement>("input[data-agent-value]")!.value).toBe("90");
  expect(saved.querySelector("[data-agent-scope]")!.textContent).toBe("Local");
  await click(setting(page.container, "claude", "model").querySelector('[data-agent-action="unset"]')!);
  expect(page.provider.agentConfigRuns.at(-1)).toEqual({
    verb: "unset",
    agent: "claude",
    key: "model",
    scope: "project",
  });
  expect(setting(page.container, "claude", "model").querySelector("[data-agent-scope]")!.textContent).toBe("Default");
  page.unmount();
});

test("a refusal shows in plain words on the row and changes nothing", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  // The CLI no longer writes Codex's user model (the page read it before): it refuses.
  page.provider.agentConfig.codex.curated[0]!.writableScopes = ["project"];
  await changeValue(
    setting(page.container, "codex", "model").querySelector<HTMLInputElement>("input[data-agent-value]")!,
    "gpt-5",
  );
  await click(setting(page.container, "codex", "model").querySelector('[data-agent-action="save"]')!);
  expect(setting(page.container, "codex", "model").querySelector("[data-agent-error]")!.textContent).toBe(
    "cmux cannot write the user scope",
  );
  expect(page.provider.agentConfig.codex.curated[0]!.value).toBe("gpt-5-codex");
  page.unmount();
});

test("a masked value never shows the secret, in the rows or under All Settings", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  const claude = agent(page.container, "claude");
  await click(claude.querySelector('[data-agent-action="all"]')!);
  const secret = claude.querySelector<HTMLElement>('[data-agent-entry="env.ANTHROPIC_API_KEY"]')!;
  expect(secret.querySelector("[data-agent-display]")!.textContent).toBe(MASK);
  expect(secret.querySelector("[data-masked]")).not.toBeNull();
  expect(page.container.textContent).not.toContain(MOCK_SECRET);
  expect(JSON.stringify(page.provider.log)).not.toContain(MOCK_SECRET);
  // The override line says where else the key is set.
  expect(claude.querySelector('[data-agent-entry="model"] [data-agent-overridden="user"]')!.textContent).toBe(
    "Also set in User: opus",
  );
  page.unmount();
});

test("Open File sends verb open with that file's path", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  const user = agent(page.container, "codex").querySelector<HTMLElement>('[data-agent-file="user"]')!;
  await click(user.querySelector('[data-agent-action="open"]')!);
  expect(page.provider.agentConfigRuns).toEqual([
    { verb: "open", agent: "codex", path: "/Users/you/.codex/config.toml" },
  ]);
  expect(agent(page.container, "codex").querySelector("[data-agent-open-error]")).toBeNull();
  page.unmount();
});

test("All Settings sits below the files, so expanding it never moves Open File", async () => {
  const page = await renderCard(<AgentCustomizationCard />, on);
  const codex = agent(page.container, "codex");
  const order = (selector: string) => [...codex.querySelectorAll("*")].indexOf(codex.querySelector(selector)!);
  expect(order('[data-agent-action="all"]')).toBeGreaterThan(order('[data-agent-file="user"]'));
  await click(codex.querySelector('[data-agent-action="all"]')!);
  // The first click on Open File after expanding opens the file.
  await click(codex.querySelector('[data-agent-file="user"] [data-agent-action="open"]')!);
  expect(page.provider.agentConfigRuns).toEqual([
    { verb: "open", agent: "codex", path: "/Users/you/.codex/config.toml" },
  ]);
  page.unmount();
});

test("a host with the lab off answers enabled false, and the card says it cannot read them", async () => {
  const page = await renderCard(<AgentCustomizationCard />, {
    ...on,
    setup: (provider) => {
      provider.agentConfigDisabled = true;
    },
  });
  expect(agent(page.container, "claude").dataset.agentPhase).toBe("unavailable");
  expect(agent(page.container, "claude").querySelector("[data-agent-unavailable]")).not.toBeNull();
  page.unmount();
});
