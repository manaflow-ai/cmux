import { jsonResponse, vmErrorResponse } from "./routeHelpers";
import type { AcpmuxOutcome, AcpmuxRefusal } from "./acpmuxPersonKey";

// HTTP answers of the two acpmux person key routes (cx-psxg). User copy
// names no vendor. A permanent refusal is never a retryable 5xx (web/AGENTS.md).

type Answer = { readonly status: number; readonly message: string; readonly action: string; readonly retryable: boolean };

const ANSWERS: Record<AcpmuxRefusal, Answer> = {
  not_single_owner: {
    status: 403,
    message: "Approvals from cmux work only on a Cloud machine that you alone own.",
    action: "Approve this machine's agent prompts on the machine itself, or use a machine of your own.",
    retryable: false,
  },
  owner_unconfirmed: {
    status: 503,
    message: "The Cloud service could not confirm that you alone own this machine.",
    action: "Try again in a moment.",
    retryable: true,
  },
  team_vm: {
    status: 403,
    message: "Approvals from cmux are off on a team machine.",
    action: "Approve this machine's agent prompts on the machine itself.",
    retryable: false,
  },
  not_running: {
    status: 409,
    message: "The machine is not running.",
    action: "Start the machine, then try again.",
    retryable: false,
  },
  unsupported: {
    status: 409,
    message: "This machine's agent daemon is too old for approvals from cmux.",
    action: "Update the machine, then try again.",
    retryable: false,
  },
  timeout: {
    status: 504,
    message: "The machine's agent daemon did not start in time.",
    action: "Try again. The machine's agents keep running.",
    retryable: true,
  },
  start_failed: {
    status: 502,
    message: "The machine's agent daemon did not start with approvals on.",
    action: "Try again. If it keeps failing, copy this error and contact support.",
    retryable: true,
  },
  holds_failed: {
    status: 502,
    message: "The machine's agent daemon did not answer the approvals check.",
    action: "Restart with approvals again.",
    retryable: true,
  },
  provider_failed: {
    status: 502,
    message: "The Cloud service could not reach the machine.",
    action: "Try again. If it keeps failing, copy this error and contact support.",
    retryable: true,
  },
};

/** The response of an outcome: its value as JSON, or the refusal's error (with the redacted guest line, when one exists). */
export function acpmuxOutcomeResponse<A extends Record<string, unknown>>(outcome: AcpmuxOutcome<A>): Response {
  if (outcome.ok) return jsonResponse(outcome.value);
  const answer = ANSWERS[outcome.refusal];
  return vmErrorResponse({
    error: `vm_acpmux_${outcome.refusal}`,
    status: answer.status,
    message: answer.message,
    action: answer.action,
    phase: "exec",
    retryable: answer.retryable,
    ...(outcome.line ? { details: { lastLine: outcome.line } } : {}),
  });
}
