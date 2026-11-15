import type { ComposerAttachment } from "../attachments";
import { composerReadback } from "../composer/externalAttach";

/// Toggle Terminal and Chat's draft on the page: the unsent draft goes with a swap, both ways
/// (Leo, 2026-11-12: two live views of one session, instant both ways). What moves is Rust's
/// (cmux-window-rules `tabs::draft`); the host reads, takes and puts the composer's text here
/// (CmuxNextAgentPane `AgentPaneView+ToggleDraft`). Only plain text leaves: a chip or an inline
/// token has no place in a terminal's input.

type Draft = { text: string; attachments: ComposerAttachment[] };

/// The composer as the swap moves its draft (Composer's `ComposerHandle`).
export type ToggleDraftComposer = {
  draft(): Draft;
  take(): Draft;
  restore(text: string, attachments: ComposerAttachment[]): void;
};

/// The composer's text when it can leave as text: no chips, no inline tokens, not blank.
export function toggleDraft(draft: Draft | undefined): string | null {
  if (!draft || draft.attachments.length > 0 || draft.text.trim() === "") return null;
  return composerReadback(draft).text === draft.text ? draft.text : null;
}

/// Empties the composer if it still holds exactly `text` (the draft the swap pasted into the
/// terminal), and only before `until` (ms since 1970): past it the chat may already show.
export function takeToggleDraft(
  composer: ToggleDraftComposer | undefined,
  text: string,
  until: number | undefined,
  now = Date.now(),
): boolean {
  if (!composer || late(until, now) || toggleDraft(composer.draft()) !== text) return false;
  composer.take();
  return true;
}

/// Puts `text` in the composer only while it is empty (two drafts are never merged), and only
/// before `until`.
export function putToggleDraft(
  composer: ToggleDraftComposer | undefined,
  text: string,
  until: number | undefined,
  now = Date.now(),
): boolean {
  if (!composer || late(until, now) || text.trim() === "") return false;
  const draft = composer.draft();
  if (draft.text !== "" || draft.attachments.length > 0) return false;
  composer.restore(text, []);
  return true;
}

const late = (until: number | undefined, now: number) => until !== undefined && now > until;

/// Reports to the host whether the composer holds anything (`pane.composerFilled`): its first value,
/// then each change. The host reads it without a page call, so a swap with an empty composer waits
/// on nothing; the first value resets what a page before a reload left there.
export function composerFilledReporter(post: (filled: boolean) => void): (filled: boolean) => void {
  let reported: boolean | undefined;
  return (filled) => {
    if (filled === reported) return;
    reported = filled;
    post(filled);
  };
}
