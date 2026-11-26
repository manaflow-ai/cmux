// Settings > General > Customize cmux: what the page hands the checklist and writes back. The steps,
// their routes and every done state come from Rust (cmux-customize `checklist.rs`, through
// `cmux --json customize checklist`); the page only reports the connections it already holds and
// writes the two settings keys a gesture changes.
import type { ChecklistFact } from "./ops";
import type { SettingsState } from "./store";

/** `customize.checklist.enabled`: Dismiss turns it off; Settings > General's switch turns it back on. */
export const CHECKLIST_ENABLED_KEY = "customize.checklist.enabled";
/** `customize.checklist.done`: the step ids checked off by hand. */
export const CHECKLIST_DONE_KEY = "customize.checklist.done";

/** The connections this page knows from the Accounts and Models parts it already reads. MCP servers and
 * a paired phone are not among them, so those steps count once checked off by hand. */
export function checklistFacts(state: Pick<SettingsState, "accounts" | "models">): ChecklistFact[] {
  const facts: ChecklistFact[] = [];
  if (state.models?.personal.connections.some((connection) => connection.signedIn)) facts.push("models");
  if ((state.accounts?.github?.connections.length ?? 0) > 0) facts.push("github");
  return facts;
}

/** The hand-checked ids after checking `id` off, or taking the check back. */
export function toggledDone(value: unknown, id: string, done: boolean): string[] {
  const ids = Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
  const rest = ids.filter((item) => item !== id);
  return done ? [...rest, id] : rest;
}
