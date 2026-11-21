/** Light or dark, for what the markdown page colors itself (code tokens, diagrams). */
export type MarkdownColorScheme = "light" | "dark";

/**
 * The page's scheme: the `markdown.theme` paper when it is fixed (`data-cmux-md-theme` light or dark,
 * whatever the App Theme), else the App Theme's (`prefers-color-scheme` follows the window's appearance).
 * styles.css keys the code tokens on the same attribute.
 */
export function markdownColorScheme(doc: Document = document): MarkdownColorScheme {
  const paper = doc.documentElement.dataset.cmuxMdTheme;
  if (paper === "light" || paper === "dark") return paper;
  return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches === true ? "dark" : "light";
}
