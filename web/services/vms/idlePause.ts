/**
 * A machine's idle auto-pause choice, in minutes (0 is Off), stored in
 * `providerMetadata.cmuxIdlePauseMinutes`.
 *
 * cmux NEXT sets it with `PUT /api/vm/{id}/idle-pause` (`cloud set-idle-pause`,
 * and `new-machine --persistent` turning it off). The server half that pauses
 * idle machines (feat-cmux-next `web/services/vms/idlePause.ts` and its
 * `vm-idle-pause` cron, 30 minutes by default) is not on main, so cmux.com
 * never pauses an idle machine (`FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS`,
 * drivers/freestyle.ts). Here the route stores Off, which every machine
 * already gets, and refuses a timeout nothing would honour. The key and the
 * values are that server's, so a machine set to Off stays Off once it lands.
 */

/** The per-machine choices the app offers, in minutes; 0 is Off. */
export const VM_IDLE_PAUSE_CHOICES = [0, 15, 30, 60, 120] as const;
export type VmIdlePauseMinutes = (typeof VM_IDLE_PAUSE_CHOICES)[number];

/** The choices this server can honour: without an idle cron, only Off. */
export const VM_IDLE_PAUSE_AVAILABLE: readonly VmIdlePauseMinutes[] = [0];

/** providerMetadata key; control-plane state, never written by a driver. */
export const VM_IDLE_PAUSE_MINUTES_KEY = "cmuxIdlePauseMinutes";

export function isVmIdlePauseMinutes(value: unknown): value is VmIdlePauseMinutes {
  return typeof value === "number" && (VM_IDLE_PAUSE_CHOICES as readonly number[]).includes(value);
}
