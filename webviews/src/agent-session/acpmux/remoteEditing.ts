import type { AcpmuxSnapshot } from "./model";
import type { StringKey } from "./i18n";

/// Harness families acpmux never lets a remote (Web) connection drive: neither Codex nor
/// opencode has a mode that asks before every edit and every command (D10,
/// plans/cmux-next/acp-remote-guard.md; acpmux `web_modes.rs` `REFUSED_FAMILIES`). Keep this
/// list in step with that one.
export const REMOTE_REFUSED_FAMILIES: readonly string[] = ["codex", "opencode"];

/// What the composer offers for the shown chat on this connection.
export type RemoteComposer = {
  /// Why sending is off, shown above the prompt.
  note?: StringKey;
  /// False: no Send button, and Enter sends nothing.
  canSend: boolean;
};

/// A remote connection showing a Codex or opencode chat cannot send: acpmux refuses it. An
/// acpmux too old to name the connection's origin cannot be trusted to refuse it, so sending to
/// those chats is off there too. The family is the session's own, else its profile name, as
/// acpmux decides it. A snapshot without an origin (no client built it) is unchanged.
export function remoteComposer(snapshot: Pick<AcpmuxSnapshot, "origin" | "summary">): RemoteComposer {
  const family = snapshot.summary?.family || snapshot.summary?.harness;
  if (!family || !REMOTE_REFUSED_FAMILIES.includes(family)) return { canSend: true };
  if (snapshot.origin === "remote") return { note: "composer.remoteUnavailable", canSend: false };
  if (snapshot.origin === "unknown") return { note: "composer.originUnknown", canSend: false };
  return { canSend: true };
}
