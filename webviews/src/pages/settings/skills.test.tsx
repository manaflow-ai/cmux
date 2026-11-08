// Settings > Skills: every skill this Mac's daemon lists, grouped by harness and source; a switch turns
// a skill (or its whole plugin) on or off by its id; New Skill checks the name and makes the skill,
// then opens it; a daemon refusal reads in the page's words; no daemon and no skills each read one
// line; search filters by name and description.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, changeValue } = await import("./testing");
const { filterSkills, groupSkills, skillIndex, skillsErrorText, validSkillName } = await import("./skills");
const { mockSkills } = await import("./mockProvider");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="skills"]')!;
const rowIds = () => [...card().querySelectorAll<HTMLElement>("[data-skill]")].map((row) => row.dataset.skill);
const row = (id: string) => card().querySelector<HTMLElement>(`[data-skill="${id}"]`)!;

async function open(setup?: (provider: MockSettingsProvider) => void) {
  page = await renderPage({ path: "/settings/skills", setup });
  await settle();
  return page;
}

test("groups: by harness, then Personal, each project, each plugin, Admin, System", () => {
  const groups = groupSkills(skillIndex(mockSkills()).skills);
  expect(groups.map((entry) => entry.harness)).toEqual(["claude", "codex"]);
  expect(groups[0]!.groups.map((group) => group.key)).toEqual([
    "claude/user/",
    "claude/project//Users/sam/code/app",
    "claude/plugin/review@team",
    "claude/admin/",
  ]);
  expect(groups[1]!.groups.map((group) => group.key)).toEqual([
    "codex/user/",
    "codex/project//Users/sam/code/app",
    "codex/system/",
  ]);
});

test("search matches every word in the name or description; the harness filter narrows it", () => {
  const index = skillIndex(mockSkills());
  expect(filterSkills(index, "triage", "all").map((skill) => skill.id)).toEqual([
    "claude:user:triage",
    "claude:project:app:triage",
  ]);
  expect(filterSkills(index, "diff secrets", "all").map((skill) => skill.id)).toEqual([
    "claude:plugin:review@team:security",
  ]);
  expect(filterSkills(index, "", "codex").every((skill) => skill.harness === "codex")).toBe(true);
  expect(skillIndex({ available: false }).skills).toEqual([]);
});

test("a name is lowercase letters, digits and hyphens, 1 to 64", () => {
  expect(validSkillName("release-notes-2")).toBe(true);
  expect(validSkillName("Release")).toBe(false);
  expect(validSkillName("has space")).toBe(false);
  expect(validSkillName("")).toBe(false);
  expect(validSkillName("a".repeat(64))).toBe(true);
  expect(validSkillName("a".repeat(65))).toBe(false);
});

test("the card lists each skill under its harness and source, with its problem and Overridden", async () => {
  await open();
  expect(card().querySelector('[data-skills-harness-group="claude"] h4')!.textContent).toBe("Claude Code");
  expect(card().querySelector('[data-skills-group="claude/project//Users/sam/code/app"]')!.textContent).toContain(
    "Project · app",
  );
  expect(card().querySelector('[data-skills-group="claude/plugin/review@team"]')!.textContent).toContain(
    "Plugin · review",
  );
  expect(rowIds()).toContain("codex:system:skill-creator");
  expect(row("claude:user:scratch").querySelector('[data-skills-problem="no_description"]')!.textContent).toBe(
    "No description",
  );
  expect(row("claude:project:app:triage").querySelector("[data-skills-shadowed]")!.textContent).toBe("Overridden");
  expect(row("claude:user:triage").dataset.enabled).toBe("false");
  // Admin and System skills have no switch.
  expect(row("claude:admin:policy").querySelector("[data-skills-toggle]")).toBeNull();
});

test("the switch turns that skill off by its id; a plugin's switch says it turns the whole plugin", async () => {
  await open();
  await click(row("claude:user:release-notes").querySelector("[data-skills-toggle]")!);
  await settle();
  expect(page!.provider.skillRuns).toEqual([
    { action: "set_enabled", id: "claude:user:release-notes", enabled: false },
  ]);
  expect(row("claude:user:release-notes").dataset.enabled).toBe("false");
  const plugin = row("claude:plugin:review@team:review").querySelector<HTMLElement>("[data-skills-toggle]")!;
  expect(plugin.dataset.skillsToggle).toBe("plugin");
  expect(plugin.getAttribute("aria-label")).toBe("Turns the whole review plugin on or off");
  await click(plugin);
  await settle();
  // Its plugin's other skill turns with it.
  expect(row("claude:plugin:review@team:security").dataset.enabled).toBe("false");
});

test("Open and Show in Finder send the row's id", async () => {
  await open();
  await click(row("codex:user:changelog").querySelector('[data-skills-action="open"]')!);
  await click(row("codex:user:changelog").querySelector('[data-skills-action="reveal"]')!);
  expect(page!.provider.skillRuns).toEqual([
    { action: "open", id: "codex:user:changelog" },
    { action: "reveal", id: "codex:user:changelog" },
  ]);
});

test("a row unfolds its file and full description", async () => {
  await open();
  const skill = row("claude:user:release-notes");
  const detail = skill.querySelector<HTMLElement>("[data-skills-detail]")!;
  expect(detail.hasAttribute("data-open")).toBe(false);
  await click(skill.querySelector("[data-skills-expand]")!);
  expect(detail.hasAttribute("data-open")).toBe(true);
  expect(detail.querySelector("[data-skills-file]")!.textContent).toBe("~/.claude/skills/release-notes/SKILL.md");
});

test("New Skill checks the name, makes the skill and opens it", async () => {
  await open();
  await click(card().querySelector('[data-skills-action="new"]')!);
  const form = card().querySelector<HTMLElement>("[data-skills-form]")!;
  const create = form.querySelector<HTMLButtonElement>('[data-skills-action="create"]')!;
  const name = form.querySelector<HTMLInputElement>('[data-skills-field="name"]')!;
  expect(create.disabled).toBe(true);
  await changeValue(name, "Bad Name");
  expect(create.disabled).toBe(true);
  expect(form.querySelector("[data-skills-rule]")!.className).toContain("field-error");
  await changeValue(name, "lint-fix");
  await changeValue(form.querySelector<HTMLInputElement>('[data-skills-field="description"]')!, "Fix lint errors");
  expect(create.disabled).toBe(false);
  await click(create);
  await settle();
  expect(page!.provider.skillRuns).toEqual([
    { action: "create", harness: "claude", scope: "user", name: "lint-fix", description: "Fix lint errors" },
    { action: "open", id: "claude:user:lint-fix" },
  ]);
  expect(rowIds()).toContain("claude:user:lint-fix");
});

test("a daemon refusal reads in the page's words", async () => {
  expect(skillsErrorText("skills.settings_unreadable")).toContain("isn’t valid");
  expect(skillsErrorText("skills.bad_name")).toBe("Lowercase letters, digits and hyphens, up to 64 characters.");
  await open((provider) => {
    provider.skillRefusal = "skills.exists";
  });
  await click(row("claude:user:release-notes").querySelector('[data-skills-action="open"]')!);
  expect(card().querySelector("[data-skills-error]")!.textContent).toBe("A skill with this name is already there.");
});

test("no skills: one line; daemon not connected: one line", async () => {
  await open((provider) => {
    provider.skills = { available: true, home: "/Users/sam", projects: [], skills: [] };
  });
  expect(card().querySelector("[data-skills-empty]")!.textContent).toBe("No skills on this Mac yet.");
  page!.unmount();
  await open((provider) => {
    provider.skills = { available: false };
  });
  expect(card().querySelector("[data-skills-unavailable]")).not.toBeNull();
  expect(rowIds()).toEqual([]);
});

test("the search field filters the rows", async () => {
  await open();
  await changeValue(card().querySelector<HTMLInputElement>("[data-skills-search]")!, "changelog");
  await settle();
  expect(rowIds()).toEqual(["codex:user:changelog"]);
  await changeValue(card().querySelector<HTMLInputElement>("[data-skills-search]")!, "nothing-like-this");
  await settle();
  expect(card().querySelector("[data-skills-no-matches]")).not.toBeNull();
});
