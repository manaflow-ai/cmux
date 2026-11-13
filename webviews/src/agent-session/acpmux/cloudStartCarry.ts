import type { ComposerAttachment } from "./attachments";

/// What the composer holds around a Cloud start (Leo, 2026-11-09: "I can't click into the composer
/// at all to, like potentially type other stuff while it's doing that initial load situation"). The
/// start takes its prompt out of the composer (App.tsx `cloudStartHeld`), so while it runs the
/// composer holds only what was typed after it. That text goes to the host as the tab's unsent text
/// (`chat.unsentDraft`), and the host seeds the started chat's composer with it (CloudStartChat
/// `openUploaded`): nothing here, and nothing in the page's own storage, carries it.
export type CloudStartDraft = { text: string; attachments: ComposerAttachment[] };

/// Whether a draft holds anything the person would miss.
export function holdsDraft(draft: CloudStartDraft | undefined): draft is CloudStartDraft {
  return Boolean(draft && (draft.text.trim() || draft.attachments.length));
}

/// A failed start's prompt went back in front of what was typed meanwhile (ComposerHandle.restore,
/// with `typed` recorded then): the prompt alone, for a Retry, Run on This Mac or sign-in that sends
/// it, when the composer still holds exactly that pair. Undefined once the person changed it: then
/// what shows is what goes.
export function promptBeforeTyped(
  composer: CloudStartDraft,
  typed: CloudStartDraft,
): { prompt: CloudStartDraft; typed: CloudStartDraft } | undefined {
  if (!holdsDraft(typed)) return undefined;
  const tail = typed.text.trim() ? `\n\n${typed.text}` : "";
  if (tail && !composer.text.endsWith(tail)) return undefined;
  const ids = new Set(typed.attachments.map((chip) => chip.id));
  if (typed.attachments.some((chip) => !composer.attachments.some((held) => held.id === chip.id))) return undefined;
  return {
    prompt: {
      text: tail ? composer.text.slice(0, -tail.length) : composer.text,
      attachments: composer.attachments.filter((chip) => !ids.has(chip.id)),
    },
    typed,
  };
}
