// The v1 attach of a chat whose rows come from the store (decision 276 a): the hold, which reads no
// log and streams only these kinds, each one the page's own state and never a row
// (acpmux-book/src/translate/kinds.rs, `PageState`). holdKinds.test.ts holds the list to that table.
// Of `subsession` the page reads only its `limits` event on a hold (`holdReads`).
import type { AttachParams } from "../protocol/generated/types";

/// Exact kinds, sorted. acpmux takes at most `HOLD_MAX_KINDS` and no category (server/requests.rs
/// `hold_attach_filter`).
export const HOLD_KINDS: readonly string[] = [
  "available_commands_update",
  "bookmarks",
  "config_option_update",
  "current_mode_update",
  "race",
  "session_info_update",
  "status",
  "subsession",
  "usage_limits",
  "usage_update",
];
export const HOLD_MAX_KINDS = 16;
/// acpmux's names for many kinds at once, which a hold refuses.
const CATEGORIES = new Set(["transcript", "mux", "wire", "all"]);

/// The hold's params: acpmux's `AttachParams` with `hold` set, only the keys a hold sends (each one the
/// relay's params rule checks).
export type HoldAttach = Pick<
  AttachParams,
  "sessionId" | "hold" | "eventStream" | "kinds" | "visible" | "attending"
> & {
  hold: true;
  eventStream: true;
  kinds: string[];
  visible: boolean;
  attending: boolean;
};

/// The hold's params, or none when its kinds are not exact page-state kinds within the bound: the
/// page sends no hold it would have to take back.
export function holdAttach(
  sessionId: string,
  visible: boolean,
  kinds: readonly string[] = HOLD_KINDS,
  attending = true,
): HoldAttach | undefined {
  if (kinds.length > HOLD_MAX_KINDS || kinds.some((kind) => !kind || CATEGORIES.has(kind))) return undefined;
  return { sessionId, hold: true, eventStream: true, kinds: [...kinds], visible, attending };
}

/// What of a record streamed on a hold the page reads: a `subsession` record only as its `limits`.
export function holdReads(event: { kind?: unknown; msg?: { event?: unknown } }): boolean {
  return event.kind !== "subsession" || event.msg?.event === "limits";
}
