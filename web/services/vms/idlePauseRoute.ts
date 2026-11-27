import { isVmIdlePauseMinutes, VM_IDLE_PAUSE_CHOICES, type VmIdlePauseMinutes } from "./idlePause";
import { vmErrorResponse } from "./routeHelpers";

type ParsedIdlePause<M> =
  | { readonly ok: true; readonly minutes: M }
  | { readonly ok: false; readonly response: Response };

/**
 * `PUT /api/vm/{id}/idle-pause` body: `{ "minutes": 15 | 30 | 60 | 120 }`, or
 * `0` or `"off"` for Off. Anything else is a 400.
 */
export function parseIdlePauseBody(body: unknown): ParsedIdlePause<VmIdlePauseMinutes> {
  const value = body && typeof body === "object" && !Array.isArray(body)
    ? (body as Record<string, unknown>).minutes
    : undefined;
  if (value === "off") return { ok: true, minutes: 0 };
  if (isVmIdlePauseMinutes(value)) return { ok: true, minutes: value };
  return {
    ok: false,
    response: vmErrorResponse({
      error: "invalid_idle_pause",
      status: 400,
      message: `minutes must be "off" or one of ${VM_IDLE_PAUSE_CHOICES.join(", ")}, got ${JSON.stringify(value) ?? "undefined"}.`,
      action: "Send `{ \"minutes\": \"off\" }` or one of the listed minutes.",
      details: { field: "minutes" },
    }),
  };
}

/**
 * `POST /api/vm`'s optional `idlePauseMinutes`: the new machine's idle
 * auto-pause, stored with the create so a persistent machine (`"off"` or 0,
 * `cmux cloud new-machine --persistent`) never runs under the default.
 * Absent: the default applies. Same values as the PUT body's `minutes`.
 */
export function parseCreateIdlePause(candidate: Record<string, unknown>): ParsedIdlePause<VmIdlePauseMinutes | undefined> {
  const value = candidate.idlePauseMinutes;
  if (value === undefined) return { ok: true, minutes: undefined };
  if (value === "off") return { ok: true, minutes: 0 };
  if (isVmIdlePauseMinutes(value)) return { ok: true, minutes: value };
  return {
    ok: false,
    response: vmErrorResponse({
      error: "invalid_idle_pause",
      status: 400,
      message: `idlePauseMinutes must be "off" or one of ${VM_IDLE_PAUSE_CHOICES.join(", ")}, got ${JSON.stringify(value)}.`,
      action: "Send `\"off\"` or one of the listed minutes, or leave `idlePauseMinutes` out for the default.",
      details: { field: "idlePauseMinutes" },
    }),
  };
}
