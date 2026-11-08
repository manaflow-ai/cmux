// Whether the person has something typed in the composer, read from the page. An ask's keys (a
// permission's y / a / n, Return and Esc; a question's digits and Return) answer from an empty
// composer, never from a half-written prompt, so typing "yes" into a draft never answers anything.

/// The prompt's typed text, without the placeholder MarkdownField keeps beside the editor.
export const composerText = (composer: Element) => composer.querySelector(".acpmux-md-root")?.textContent?.trim() ?? "";

/// The composer prompt `element` types into (its editor, under MarkdownField's root), if it is one.
export function composerPromptOf(element: Element | null): Element | null {
  return element?.closest(".acpmux-md-root")?.closest(".acpmux-composer-prompt") ?? null;
}

/// Whether the page's composer holds a draft: text in the prompt, or a command in its shell field.
export function composerHasDraft(document: Document): boolean {
  const composer = document.querySelector(".acpmux-composer-prompt");
  const shell = document.querySelector<HTMLTextAreaElement>(".acpmux-shell-field");
  return (composer !== null && composerText(composer) !== "") || Boolean(shell?.value.trim());
}
