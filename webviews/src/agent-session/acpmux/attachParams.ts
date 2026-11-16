// The kinds a v1 attach asks for by name, and its plain params (direct.ts `sendAttach`). A chat whose
// rows come from the store asks its hold instead (rows/holdKinds.ts).
import type { AttachParams } from "./protocol/generated/types";
import { BOOKMARKS_KIND } from "./threadMinimap/bookmarks";

/// The slash commands are not transcript, so the pane asks for their updates by kind.
export const COMMANDS_KIND = "available_commands_update";
/// How much of the context window the session has used; not transcript, so attach asks for it by kind.
export const USAGE_KIND = "usage_update";
/// The agent's own change of a config option (a reasoning level, a model): the whole option list.
export const CONFIG_KIND = "config_option_update";
/// An agent's secret card and its answer (cx-ncc.42): not transcript, so attach asks for them by kind.
export const SECRET_KINDS = ["secret_request", "secret_decision"];
/// A sudo card and its answer (acpmux hub/elevation.rs): only this machine's own chats ask, so only
/// a local attach asks for them (a peer's attach stays at 8 kinds).
export const ELEVATION_KINDS = ["elevation_request", "elevation_decision"];
/// A no-prompt preset's approval card and its answer (acpmux hub/unattended_presets.rs): the chat
/// whose agent tried to start a chat on another machine gets them, on this machine's acpmux, so
/// only a local attach asks for them as for the sudo card.
export const PRESET_APPROVAL_KINDS = ["preset_approval_request", "preset_approval_decision"];
/// A queued prompt sent now (`queue_order` `next`) or edited (`queue_updated`): not transcript in
/// acpmux (`paging.rs`), so attach asks for them by kind, or the queue never hears either live.
/// `prompt_refused`: acpmux refused a prompt sent now at dispatch (hub/web_control.rs), after it left the
/// queue; it is not a transcript record, so the pane asks for it by name.
export const QUEUE_KINDS = ["queue_order", "queue_updated", "prompt_refused"];
/// acpmux's sub-session records (hub/subsessions.rs `RECORD_KIND`): a child started or ended, and
/// the chat's `limits` changing.
export const SUBSESSION_KIND = "subsession";

/// The attach of a chat drawn by v1: its newest page, then its records live.
export function plainAttach(
  sessionId: string,
  options: { settled: boolean; visible: boolean; local: boolean; maxBytes: number },
): AttachParams {
  return {
    sessionId,
    // The visible page must not wait for the daemon's restart-time full-log restoration. The
    // attach page can read the newest records directly; queue/status restoration continues in
    // the daemon and arrives on the attached event stream (Leo: the window must be well under 1 s).
    waitLogs: false,
    // The chat's settled view first (cmuxterm-hq#9655): acpmux keys it on these page bounds, which
    // stay the same on every open of the pane; it carries the queue a restarted acpmux has not read.
    ...(options.settled ? { settled: true } : {}),
    limit: 400,
    // The most opening a chat downloads, however large its tool output (a remote session's open).
    maxBytes: options.maxBytes,
    // At most 8 kinds: a remote cmux-tui before cx-kpd0v refuses more. Session offers come with
    // "transcript" (acpmux paging.rs, since offers exist). The queue's live kinds go only to a
    // local acpmux, which takes any number; a remote chat's queue follows its session changes.
    kinds: [
      "transcript",
      COMMANDS_KIND,
      USAGE_KIND,
      CONFIG_KIND,
      BOOKMARKS_KIND,
      ...SECRET_KINDS,
      // The chat's sub-session records: its running limit's `limits` changes (the eighth kind).
      SUBSESSION_KIND,
      ...(options.local ? [...QUEUE_KINDS, ...ELEVATION_KINDS, ...PRESET_APPROVAL_KINDS] : []),
    ],
    eventStream: true,
    visible: options.visible,
  };
}

/// The capability id an acpmux that keeps each chat's settled view names (cmuxterm-hq#9655 stage 1):
/// written at every turn end, it answers `_acpmux/attach { settled: true }` first, with the records
/// logged after it, its queue and its fork points, even before a restarted acpmux read the chat's log.
export const SETTLED_ATTACH_CAPABILITY = "settled-attach-v1";

/// Whether an attach failed over its settled view (`settled: true`, `settled-attach-v1`): its error
/// names `settled` (its message, code or reason). Any other failure (the session gone, the socket
/// closed) fails a plain attach too.
export function settledAttachFailed(error: unknown): boolean {
  const failure = error as { message?: unknown; code?: unknown; reason?: unknown } | undefined;
  // A host whose params rule does not take `settled` refuses the attach as malformed (#42185).
  if (failure?.code === "transport.intent_invalid") return true;
  return [failure?.message, failure?.code, failure?.reason].some(
    (said) => typeof said === "string" && /settled/i.test(said),
  );
}

/// The chat's detail an attach reply carries, naming the machine it runs on. A reply acpmux forwarded
/// from a peer names that peer at its top level only (`server/peer_forward.rs`): its `session` is the
/// peer daemon's own detail, with no `peer`, so the detail alone read as this Mac's chat and Session
/// Info named this Mac for a peer's chat (Leo, 2026-11-07: "hmm is the session info not accurately
/// describing machine provenance?").
export function attachedDetail(result: unknown): Record<string, any> {
  const reply = result as { session?: unknown; peer?: unknown } | undefined;
  const detail = reply?.session && typeof reply.session === "object" ? (reply.session as Record<string, any>) : {};
  return typeof reply?.peer === "string" && reply.peer && !(typeof detail.peer === "string" && detail.peer)
    ? { ...detail, peer: reply.peer }
    : detail;
}
