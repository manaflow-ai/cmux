/**
 * Puts a new chat's inherited draft (a terminal selection, a page's URL) in the
 * composer, caret at the end. It never sends, and never replaces text the user
 * already typed. Returns whether it filled the composer.
 */
export function seedComposer(prompt: HTMLTextAreaElement | null | undefined, draft: unknown): boolean {
  if (!prompt || typeof draft !== "string" || !draft.trim() || prompt.value) return false;
  prompt.value = draft;
  prompt.setSelectionRange(draft.length, draft.length);
  return true;
}
