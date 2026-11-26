// Extension context chips (`cmux.composer.chip/1`) in a row over the composer's prompt. The daemon
// decides which there are (cmux-tui-core apps/composer.rs `chips`, in `apps.composer.list` through
// the page host's `cmux.apps.panels.composer`); this file only reads its answer, which lists again
// when the installed apps change, so a save of a local extension's manifest redraws the row.
import { useComposerContribution } from "./extensionCommands";
import type { PageClient } from "../../../pages/shared/pageClient";

/// One chip, as the daemon answers it: a click writes `insert` into the draft.
export type ExtensionChip = {
  app: string;
  extension: string;
  id: string;
  label: string;
  detail?: string;
  insert: string;
};

const NONE: readonly ExtensionChip[] = [];

/// The chips in an `apps.composer.list` reply; an entry with no id, label or insert text is dropped,
/// as is a second one of the same app and id.
export function extensionChipsFrom(reply: unknown): ExtensionChip[] {
  const chips = (reply as { chips?: unknown } | null)?.chips;
  if (!Array.isArray(chips)) return [];
  const out: ExtensionChip[] = [];
  const seen = new Set<string>();
  for (const entry of chips) {
    if (!entry || typeof entry !== "object") continue;
    const { app, extension, id, label, detail, insert } = entry as Record<string, unknown>;
    if (typeof id !== "string" || !id || typeof label !== "string" || !label) continue;
    if (typeof insert !== "string" || !insert) continue;
    const appId = typeof app === "string" ? app : "";
    const key = `${appId}\u0000${id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({
      app: appId,
      extension: typeof extension === "string" ? extension : "",
      id,
      label,
      ...(typeof detail === "string" && detail && { detail }),
      insert,
    });
  }
  return out;
}

/// `text` with `insert` written at `caret`, set off from the words around it by one space each
/// side; the caret lands after it.
export function withChipText(text: string, caret: number, insert: string): { text: string; caret: number } {
  const at = Math.max(0, Math.min(caret, text.length));
  const before = text.slice(0, at);
  const after = text.slice(at);
  const lead = before && !/\s$/.test(before) ? " " : "";
  const trail = after && !/^\s/.test(after) ? " " : "";
  const written = lead + insert + trail;
  return { text: before + written + after, caret: at + lead.length + insert.length + trail.length };
}

export function useExtensionChips(injectedClient?: PageClient | null): readonly ExtensionChip[] {
  return useComposerContribution<readonly ExtensionChip[]>(extensionChipsFrom, NONE, injectedClient);
}
