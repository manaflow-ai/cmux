import type { AcpmuxSnapshot } from "./model";
import type { StringKey } from "./i18n";

/// Harness families acpmux lets a remote (Web) connection drive only in a mode that does not
/// edit: Codex in `read-only`, opencode in `plan`. Neither harness has a mode that asks before
/// every edit and every command, so none is open to a remote connection for editing
/// (plans/cmux-next/acp-remote-guard.md, "Modes", and acpmux `web_modes.rs` `ASKING_MODES`).
/// Keep this list in step with that table.
export const REMOTE_NO_EDIT_FAMILIES: readonly string[] = ["codex", "opencode"];

/// The composer's note for a remote connection showing a chat it may not edit through, or
/// nothing. The family is the session's own, else its profile name, as acpmux decides it.
export function remoteEditingNote(snapshot: Pick<AcpmuxSnapshot, "remote" | "summary">): StringKey | undefined {
  if (!snapshot.remote || !snapshot.summary) return undefined;
  const family = snapshot.summary.family || snapshot.summary.harness;
  return family && REMOTE_NO_EDIT_FAMILIES.includes(family) ? "composer.remoteEditing" : undefined;
}
