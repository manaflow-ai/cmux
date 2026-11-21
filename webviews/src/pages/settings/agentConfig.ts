// Settings > Agents > Claude Code & Codex: the Labs switch that shows the card and the words for
// a config scope (`user`, `project`, `local`, `managed`, `profile:NAME`), shared by the card, the
// mock and the tests.
import type { AgentConfigAgent } from "./ops";
import { t } from "./strings";

/** The Labs switch (schemas/settings/source/labs.json); off, the card draws nothing. */
export const AGENT_CUSTOMIZATION_LAB = "labs.agentCustomization";

/** The agents the card shows, in its order. */
export const AGENT_CONFIG_AGENTS: readonly AgentConfigAgent[] = ["claude", "codex"];

const SCOPES = new Set(["user", "project", "local", "managed"]);

/** A scope as the page says it: User, Project, Local, Managed, Profile fast. */
export function scopeLabel(scope: string): string {
  if (scope.startsWith("profile:"))
    return t("settingsWindow.agentConfig.scope.profile", scope.slice("profile:".length));
  return SCOPES.has(scope) ? t(`settingsWindow.agentConfig.scope.${scope}`) : scope;
}

/** The scope a change goes to first: User where it is writable, else the first writable one. */
export function defaultScope(writable: readonly string[]): string {
  return writable.includes("user") ? "user" : (writable[0] ?? "user");
}
