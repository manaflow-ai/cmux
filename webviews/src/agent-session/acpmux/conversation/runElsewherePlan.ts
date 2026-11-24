import { translate } from "../i18n";
import { firstMachine, type RunElsewhere as Runs, type RunPlan, type RunState } from "./runElsewhereModel";

/** What a plan's answer leaves under the row: the panel when a machine can take the run, else one
 * quiet line that says why it stays here (nothing to press: the line is the whole answer). */
export function afterPlan(plan: RunPlan, last?: string): RunState {
  if (!plan.eligible) return { phase: "note", text: translate("runElsewhere.stays", { why: plan.why ?? "" }) };
  // A machine connected later can take it: the chip stays, beside the line, to ask again.
  if (plan.machines.length === 0) return { phase: "note", text: translate("runElsewhere.noMachine"), retry: true };
  return { phase: "choosing", plan, machine: firstMachine(plan.machines, last), send: [] };
}

/** What a failed plan leaves under the row. The pane's host refusing to relay it (not on its relay
 * allowlist, `transport.method_refused`: acpmux never saw the ask) means this build cannot move
 * commands at all, so the chip goes from every row; any other transport error (a dropped
 * connection) passes. acpmux's own refusal says its reason. */
export function afterPlanError(runs: Runs, error: unknown): RunState {
  if ((error as { code?: unknown } | null)?.code === "transport.method_refused") {
    runs.store.hostRefused();
    return { phase: "note", text: translate("runElsewhere.unavailable") };
  }
  const why = String((error as Error)?.message ?? error);
  // acpmux's refusal (a JSON-RPC code) names why the command stays; anything else (this chat lost
  // its connection) is its own sentence.
  const fromAcpmux = typeof error === "object" && error !== null && "code" in error;
  // A lost connection passes: the chip stays to ask again once the chat is back.
  return fromAcpmux
    ? { phase: "note", text: translate("runElsewhere.stays", { why }) }
    : { phase: "note", text: why, retry: true };
}
