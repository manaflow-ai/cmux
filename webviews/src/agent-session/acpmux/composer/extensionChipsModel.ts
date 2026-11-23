// Extension context chips (`cmux.composer.chip/1`) in a row above the draft. The daemon decides
// which there are (cmux-tui-core apps/composer.rs, `apps.composer.list` `chips`: enabled, visible
// apps, at most 24, no two writing the same text), and a save of an extension's cmux-app.json lists
// them again (`cmux.apps.panels.changed`). This file only reads that answer and works out the text a
// click adds at the caret; the row draws nothing while no extension adds a chip.
import type { PageClient } from "../../../pages/shared/pageClient";
import { useComposerContribution } from "./extensionCommands";

export type ExtensionChip = {
  /// The chip's key: its app and its id, as the interface says.
  key: string;
  app: string;
  extension?: string;
  label: string;
  detail?: string;
  insert: string;
};

const EMPTY: readonly ExtensionChip[] = [];

/// The chips in an `apps.composer.list` reply; an entry with no app, id, label or text is dropped,
/// and so is a second chip with the same key.
export function extensionChipsFrom(reply: unknown): ExtensionChip[] {
  const chips = (reply as { chips?: unknown } | null)?.chips;
  if (!Array.isArray(chips)) return [];
  const out: ExtensionChip[] = [];
  const keys = new Set<string>();
  for (const entry of chips) {
    if (!entry || typeof entry !== "object") continue;
    const { app, id, label, insert, detail, extension } = entry as Record<string, unknown>;
    if (typeof app !== "string" || !app || typeof id !== "string" || !id) continue;
    if (typeof label !== "string" || !label || typeof insert !== "string" || !insert) continue;
    const key = `${app}/${id}`;
    if (keys.has(key)) continue;
    keys.add(key);
    out.push({
      key,
      app,
      label,
      insert,
      ...(typeof extension === "string" && extension && { extension }),
      ...(typeof detail === "string" && detail && { detail }),
    });
  }
  return out;
}

/// What a click writes at the caret: the chip's text, with a space before it when the text before
/// the caret ends in a word, and one after it so the next word the person types stands apart.
export function chipText(before: string, insert: string): string {
  const spaced = !before || /(\s|&#x20;|&#32;|&nbsp;)$/i.test(before);
  return `${spaced ? "" : " "}${insert}${/\s$/.test(insert) ? "" : " "}`;
}

/// The chip's tooltip: its detail, then the extension that adds it.
export function chipTitle(chip: ExtensionChip): string {
  return [chip.detail, chip.extension].filter(Boolean).join(" · ");
}

export function useExtensionChips(injectedClient?: PageClient | null): readonly ExtensionChip[] {
  return useComposerContribution<readonly ExtensionChip[]>(extensionChipsFrom, EMPTY, injectedClient);
}
