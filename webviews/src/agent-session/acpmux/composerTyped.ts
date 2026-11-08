// Whether the person has something typed in the composer, read from the page. An ask's keys (a
// permission's y / a / n, Return and Esc; a question's digits and Return) answer from an empty
// composer, never from a half-written prompt, so typing "yes" into a draft never answers anything.

/// The prompt's typed text, without the placeholder MarkdownField keeps beside the editor.
export const composerText = (composer: Element) => composer.querySelector(".acpmux-md-root")?.textContent?.trim() ?? "";

/// Whether a composer prompt holds a draft: typed text, or files attached (or still being read).
export function promptHoldsDraft(composer: Element): boolean {
  return composerText(composer) !== "" || composer.querySelector("[data-draft-attachments]") !== null;
}

/// The composer prompt `element` types into (its editor, under MarkdownField's root), if it is one.
export function composerPromptOf(element: Element | null): Element | null {
  return element?.closest(".acpmux-md-root")?.closest(".acpmux-composer-prompt") ?? null;
}

/// Whether the page's composer holds a draft: in the prompt (promptHoldsDraft), or a command in its
/// shell field.
export function composerHasDraft(document: Document): boolean {
  const composer = document.querySelector(".acpmux-composer-prompt");
  const shell = document.querySelector<HTMLTextAreaElement>(".acpmux-shell-field");
  return (composer !== null && promptHoldsDraft(composer)) || Boolean(shell?.value.trim());
}
