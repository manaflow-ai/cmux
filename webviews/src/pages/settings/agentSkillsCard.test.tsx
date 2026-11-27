// Settings > Agents > Claude Code & Codex > Skills: nothing while Labs `labs.agentCustomization` is
// off; on, every skill and command per agent with its scope and file, a filter, Edit and Reveal that
// name a listed file, and a switch that writes only on a click (commands have none).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { AgentSkillRow } from "./ops";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="agentSkills"]');

/** 40 Claude Code skills, 2 commands and 30 Codex skills: Leo's Mac's size, and then some. */
function rows(): AgentSkillRow[] {
  const claude = Array.from({ length: 40 }, (_, i): AgentSkillRow => ({
    agent: "claude",
    kind: "skill",
    scope: i < 36 ? "user" : "project",
    name: `skill-${String(i).padStart(2, "0")}`,
    description: `Claude skill number ${i}`,
    path: `/Users/me/.claude/skills/skill-${i}/SKILL.md`,
    enabled: i !== 3,
    override: i === 3 ? "off" : undefined,
    switchFile: "/Users/me/.claude/settings.json",
  }));
  const commands: AgentSkillRow[] = ["ship", "sub:deep"].map((name) => ({
    agent: "claude",
    kind: "command",
    scope: "user",
    name,
    description: "",
    path: `/Users/me/.claude/commands/${name.replace(":", "/")}.md`,
    enabled: true,
  }));
  const codex = Array.from({ length: 30 }, (_, i): AgentSkillRow => ({
    agent: "codex",
    kind: "skill",
    scope: i < 25 ? "user" : "plugin",
    name: i < 25 ? `codex-${i}` : `pdf:pdf-${i}`,
    description: "A Codex skill about wrangler",
    path: `/Users/me/.codex/skills/codex-${i}/SKILL.md`,
    plugin: i < 25 ? undefined : "pdf@openai-primary-runtime",
    enabled: true,
    switchFile: "/Users/me/.codex/config.toml",
  }));
  return [...claude, ...commands, ...codex];
}

const on = (provider: { agentSkills: unknown }) => {
  provider.agentSkills = {
    enabled: true,
    loading: false,
    problem: null,
    skills: rows(),
    problems: [
      { agent: "codex", path: "/Users/me/.codex/skills/broken/SKILL.md", message: "missing field `description`" },
    ],
    sources: { claude: "files", codex: "app-server" },
    elapsedMs: 12,
    refusal: null,
  };
};

test("with Labs off the card is not drawn and nothing is listed", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  expect(card(page.container)).toBeNull();
  expect(page.provider.agentSkillRuns).toEqual([]);
  page.unmount();
});

test("on: every skill and command per agent, counts, scope and file, in one render", async () => {
  const started = performance.now();
  const page = await renderPage({ path: "/settings/agents", setup: on });
  await settle();
  const element = card(page.container)!;
  const elapsed = performance.now() - started;
  expect(element.textContent).toContain("Claude Code & Codex");
  expect(element.querySelectorAll("[data-agent-skill]").length).toBe(72);
  const counts = [...element.querySelectorAll("[data-agent-skills-count]")].map((node) => node.textContent);
  expect(counts).toEqual(["39 of 40 skills on · 2 of 2 commands on", "30 of 30 skills on"]);
  const row = element.querySelector<HTMLElement>('[data-agent-skill="claude:skill-36"]')!;
  expect(row.textContent).toContain("/skill-36");
  expect(row.textContent).toContain("Project");
  expect(row.textContent).toContain("/Users/me/.claude/skills/skill-36/SKILL.md");
  expect(element.querySelector('[data-agent-skill="codex:pdf:pdf-26"]')!.textContent).toContain("$pdf:pdf-26");
  expect(element.querySelector("[data-agent-skills-skipped]")!.textContent).toContain("missing field `description`");
  // A slash command has no switch in its agent.
  const command = element.querySelector<HTMLElement>('[data-agent-skill="claude:ship"]')!;
  expect(command.querySelector('[role="switch"]')).toBeNull();
  expect(command.querySelector("[data-agent-skill-no-switch]")).not.toBeNull();
  // 72 rows render well inside a frame budget's worth of work in the test DOM.
  console.log(`agentSkills render: 72 rows in ${elapsed.toFixed(1)} ms`);
  expect(elapsed).toBeLessThan(2000);
  page.unmount();
});

test("the filter narrows by name, description or file", async () => {
  const page = await renderPage({ path: "/settings/agents", setup: on });
  await settle();
  const element = card(page.container)!;
  const input = element.querySelector<HTMLInputElement>("[data-agent-skills-filter]")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "wrangler");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await settle();
  expect(element.querySelectorAll('[data-agent-skill^="claude:"]').length).toBe(0);
  expect(element.querySelectorAll('[data-agent-skill^="codex:"]').length).toBe(30);
  page.unmount();
});

test("Edit and Reveal name the row's file; the switch turns it off on a click", async () => {
  const page = await renderPage({ path: "/settings/agents", setup: on });
  await settle();
  const element = card(page.container)!;
  const row = element.querySelector<HTMLElement>('[data-agent-skill="claude:skill-01"]')!;
  await act(async () => row.querySelector<HTMLButtonElement>('[data-agent-skill-action="open"]')!.click());
  await act(async () => row.querySelector<HTMLButtonElement>('[data-agent-skill-action="reveal"]')!.click());
  await act(async () => row.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  await settle();
  const path = "/Users/me/.claude/skills/skill-1/SKILL.md";
  expect(page.provider.agentSkillRuns).toEqual([
    { action: "open", path },
    { action: "reveal", path },
    { action: "off", path, agent: "claude" },
  ]);
  expect(
    card(page.container)!.querySelector<HTMLElement>('[data-agent-skill="claude:skill-01"]')!.dataset.agentSkillOn,
  ).toBe("false");
  page.unmount();
});

/** Types `value` into a New Command field the way a person does. */
async function fill(element: HTMLElement, field: string, value: string) {
  const control = element.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(
    `[data-agent-command-field="${field}"]`,
  )!;
  await act(async () => {
    const proto = Object.getPrototypeOf(control) as object;
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(control, value);
    control.dispatchEvent(new Event(control.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
  });
}

const click = async (element: HTMLElement, action: string) =>
  act(async () => element.querySelector<HTMLButtonElement>(`[data-agent-skill-action="${action}"]`)!.click());

test("New Command saves a prompt as a Claude Code slash command, listed at once", async () => {
  const page = await renderPage({ path: "/settings/agents", setup: on });
  await settle();
  const element = card(page.container)!;
  expect(element.querySelector("[data-agent-command-form]")).toBeNull();
  await click(element, "newCommand");
  const form = card(page.container)!.querySelector<HTMLElement>("[data-agent-command-form]")!;
  const save = () => form.querySelector<HTMLButtonElement>('[data-agent-skill-action="confirmNewCommand"]')!;
  expect(save().disabled).toBe(true);
  await fill(form, "name", "/standup");
  await fill(form, "prompt", "Write my standup from today's commits.");
  expect(form.textContent).toContain("/standup");
  expect(save().disabled).toBe(false);
  await click(form, "confirmNewCommand");
  await settle();
  expect(page.provider.agentSkillRuns).toEqual([
    { action: "add", agent: "claude", name: "standup", prompt: "Write my standup from today's commits." },
  ]);
  const after = card(page.container)!;
  expect(after.querySelector("[data-agent-command-form]")).toBeNull();
  expect(after.querySelector('[data-agent-skill="claude:standup"]')).not.toBeNull();
  expect(after.querySelector("[data-agent-command-added]")!.textContent).toContain("~/.claude/commands/standup.md");
  page.unmount();
}, 20_000);

test("New Command for every chat or Codex names what to type; a taken name is refused in the form", async () => {
  const page = await renderPage({ path: "/settings/agents", setup: on });
  await settle();
  await click(card(page.container)!, "newCommand");
  let form = card(page.container)!.querySelector<HTMLElement>("[data-agent-command-form]")!;
  await fill(form, "agent", "codex");
  await fill(form, "name", "review");
  expect(form.textContent).toContain("/prompts:review");
  await fill(form, "agent", "cmux");
  await fill(form, "description", "Review the diff");
  await fill(form, "prompt", "Review the staged diff.");
  await click(form, "confirmNewCommand");
  await settle();
  expect(page.provider.agentSkillRuns.at(-1)).toEqual({
    action: "add",
    agent: "cmux",
    name: "review",
    prompt: "Review the staged diff.",
    description: "Review the diff",
  });
  expect(card(page.container)!.querySelector("[data-agent-command-added]")!.textContent).toContain("/review");
  // A name Claude Code already has: the CLI's refusal shows and the form stays open.
  await click(card(page.container)!, "newCommand");
  form = card(page.container)!.querySelector<HTMLElement>("[data-agent-command-form]")!;
  await fill(form, "agent", "claude");
  await fill(form, "name", "ship");
  await fill(form, "prompt", "Ship it.");
  await click(form, "confirmNewCommand");
  await settle();
  const refused = card(page.container)!.querySelector<HTMLElement>("[data-agent-command-form]")!;
  expect(refused.querySelector("[data-agent-command-refusal]")!.textContent).toContain("already exists");
  page.unmount();
}, 20_000);
