// Settings > Skills (Leo 2026-11-08): the groups the card draws from this Mac's daemon's skills
// (`cmux.settings.skills.list`, the daemon's `skills-list`), the search index that filters them, the
// New Skill name rule and the text for a daemon refusal. The daemon finds, toggles and makes every
// skill; the page only shapes what it answers and forwards each gesture.
import type { Skill, SkillHarness, SkillScope, SkillsState } from "./ops";
import { t } from "./strings";

export const HARNESSES: readonly SkillHarness[] = ["claude", "codex"];
const SCOPES: readonly SkillScope[] = ["user", "project", "plugin", "admin", "system"];

/** The harness filter: every harness, or one. */
export type HarnessFilter = "all" | SkillHarness;

/** One run of rows under a header: a harness's personal skills, one project's, one plugin's. */
export type SkillGroup = {
  key: string;
  harness: SkillHarness;
  scope: SkillScope;
  /** The project's root or the plugin's id, for a project or plugin group. */
  source: string | null;
  skills: Skill[];
};

/** One harness's groups, in scope order. */
export type HarnessGroups = { harness: SkillHarness; groups: SkillGroup[] };

/** A skill's search text, lowercased once per list (the index), so a keystroke only scans strings. */
export type SkillIndex = { skills: Skill[]; text: string[] };

export function skillIndex(state: SkillsState | null | undefined): SkillIndex {
  const skills = state?.available ? (state.skills ?? []) : [];
  return { skills, text: skills.map((skill) => `${skill.name}\n${skill.description}`.toLowerCase()) };
}

/** The skills that match every word of `query` (name or description) and the harness filter, in
 * the daemon's order. */
export function filterSkills(index: SkillIndex, query: string, harness: HarnessFilter): Skill[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return index.skills.filter(
    (skill, at) =>
      (harness === "all" || skill.harness === harness) && words.every((word) => index.text[at]!.includes(word)),
  );
}

/** The rows by harness, then scope; a project's and a plugin's rows each get a group of their own. */
export function groupSkills(skills: readonly Skill[]): HarnessGroups[] {
  const byKey = new Map<string, SkillGroup>();
  for (const skill of skills) {
    const source = skill.scope === "project" ? skill.project : skill.scope === "plugin" ? skill.plugin : null;
    const key = `${skill.harness}/${skill.scope}/${source ?? ""}`;
    let group = byKey.get(key);
    if (!group) {
      group = { key, harness: skill.harness, scope: skill.scope, source, skills: [] };
      byKey.set(key, group);
    }
    group.skills.push(skill);
  }
  const order = (group: SkillGroup) => HARNESSES.indexOf(group.harness) * 10 + SCOPES.indexOf(group.scope);
  const groups = [...byKey.values()].sort(
    (a, b) => order(a) - order(b) || (a.source ?? "").localeCompare(b.source ?? ""),
  );
  return HARNESSES.map((harness) => ({ harness, groups: groups.filter((group) => group.harness === harness) })).filter(
    (entry) => entry.groups.length > 0,
  );
}

/** A skill's name as the daemon accepts it (skills_catalog.rs `valid_name`): lowercase letters and
 * digits in words joined by single hyphens, at most 64 characters. */
export function validSkillName(name: string): boolean {
  // `synced` is the folder Claude Code syncs skills into, never one skill (the daemon refuses it).
  return name !== "synced" && name.length <= 64 && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name);
}

export function harnessTitle(harness: SkillHarness): string {
  return t(`settingsPage.skills.harness.${harness}`);
}

export function scopeTitle(scope: SkillScope): string {
  return t(`settingsPage.skills.scope.${scope}`);
}

/** A project's folder name from its root, as the daemon lists it (else the root's last part). */
export function projectName(state: SkillsState | null | undefined, root: string): string {
  return (
    state?.projects?.find((project) => project.root === root)?.name ?? root.split("/").filter(Boolean).at(-1) ?? root
  );
}

/** A plugin's name without its marketplace (`review@team` reads `review`). */
export function pluginName(plugin: string): string {
  const at = plugin.indexOf("@");
  return at > 0 ? plugin.slice(0, at) : plugin;
}

/** A path under the person's home as `~/…`. */
export function shortPath(path: string, home: string | undefined): string {
  return home && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
}

/** The tag a row carries for its mode, when the daemon names one the page knows. */
export function modeTitle(mode: string | null): string | null {
  if (mode === "name-only") return t("settingsPage.skills.mode.nameOnly");
  if (mode === "user-invocable-only") return t("settingsPage.skills.mode.userInvocableOnly");
  return null;
}

const ERRORS = new Set([
  "not_found",
  "not_toggleable",
  "settings_unreadable",
  "write_failed",
  "not_trusted",
  "exists",
  "bad_scope",
]);

/** A refusal's text: a daemon code (`skills.exists`) in the page's words, anything else as is. */
export function skillsErrorText(error: string): string {
  const code = error.startsWith("skills.") ? error.slice("skills.".length) : null;
  if (code === "bad_name") return t("settingsPage.skills.nameRule");
  if (code && ERRORS.has(code)) return t(`settingsPage.skills.error.${code}`);
  return t("settingsPage.skills.error.failed", error);
}
