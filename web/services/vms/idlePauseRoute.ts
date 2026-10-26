import {
  isVmIdlePauseMinutes,
  VM_IDLE_PAUSE_AVAILABLE,
  VM_IDLE_PAUSE_CHOICES,
  type VmIdlePauseMinutes,
} from "./idlePause";
import { vmErrorResponse } from "./routeHelpers";

type ParsedIdlePause =
  | { readonly ok: true; readonly minutes: VmIdlePauseMinutes }
  | { readonly ok: false; readonly response: Response };

/**
 * `PUT /api/vm/{id}/idle-pause` body: `{ "minutes": 15 | 30 | 60 | 120 }`, or
 * `0` or `"off"` for Off. A value outside those is a 400; a valid timeout this
 * server cannot honour (services/vms/idlePause.ts) is a 409.
 */
export function parseIdlePauseBody(body: unknown): ParsedIdlePause {
  const value = body && typeof body === "object" && !Array.isArray(body)
    ? (body as Record<string, unknown>).minutes
    : undefined;
  const minutes = value === "off" ? 0 : value;
  if (!isVmIdlePauseMinutes(minutes)) {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "invalid_idle_pause",
        status: 400,
        message: `minutes must be "off" or one of ${VM_IDLE_PAUSE_CHOICES.join(", ")}, got ${JSON.stringify(value) ?? "undefined"}.`,
        action: "Send `{ \"minutes\": \"off\" }`.",
        details: { field: "minutes" },
      }),
    };
  }
  if (!VM_IDLE_PAUSE_AVAILABLE.includes(minutes)) {
    return {
      ok: false,
      response: vmErrorResponse({
        error: "idle_pause_unavailable",
        status: 409,
        message: "cmux Cloud does not pause idle machines yet, so the only idle pause setting is Off.",
        action: "Pause the machine yourself when you are done, or choose Off.",
        retryable: false,
        details: { field: "minutes", minutes, available: VM_IDLE_PAUSE_AVAILABLE },
      }),
    };
  }
  return { ok: true, minutes };
}
