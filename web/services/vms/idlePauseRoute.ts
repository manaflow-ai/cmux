import { isVmIdlePauseMinutes, VM_IDLE_PAUSE_CHOICES, type VmIdlePauseMinutes } from "./idlePause";
import { jsonResponse } from "./routeHelpers";

/**
 * `PUT /api/vm/{id}/idle-pause` body: `{ "minutes": 15 | 30 | 60 | 120 }`, or
 * `0` or `"off"` for Off.
 */
export function parseIdlePauseBody(
  body: unknown,
): { readonly ok: true; readonly minutes: VmIdlePauseMinutes } | { readonly ok: false; readonly response: Response } {
  const value = body && typeof body === "object" && !Array.isArray(body)
    ? (body as Record<string, unknown>).minutes
    : undefined;
  if (value === "off") return { ok: true, minutes: 0 };
  if (isVmIdlePauseMinutes(value)) return { ok: true, minutes: value };
  return {
    ok: false,
    response: jsonResponse({
      error: "invalid_idle_pause",
      message: `minutes must be "off" or one of ${VM_IDLE_PAUSE_CHOICES.join(", ")}, got ${JSON.stringify(value) ?? "undefined"}.`,
    }, 400),
  };
}

/**
 * `POST /api/vm`'s optional `idlePauseMinutes`: the new machine's idle
 * auto-pause, stored with the create so a persistent machine (`"off"` or 0,
 * `cmux cloud new-machine --persistent`) never runs under the default.
 * Absent: the default applies. Same values as the PUT body's `minutes`.
 */
export function parseCreateIdlePause(
  candidate: Record<string, unknown>,
): { readonly ok: true; readonly minutes: VmIdlePauseMinutes | undefined } | { readonly ok: false; readonly response: Response } {
  const value = candidate.idlePauseMinutes;
  if (value === undefined) return { ok: true, minutes: undefined };
  if (value === "off") return { ok: true, minutes: 0 };
  if (isVmIdlePauseMinutes(value)) return { ok: true, minutes: value };
  return {
    ok: false,
    response: jsonResponse({
      error: "invalid_idle_pause",
      message: `idlePauseMinutes must be "off" or one of ${VM_IDLE_PAUSE_CHOICES.join(", ")}, got ${JSON.stringify(value)}.`,
      details: { field: "idlePauseMinutes" },
    }, 400),
  };
}
