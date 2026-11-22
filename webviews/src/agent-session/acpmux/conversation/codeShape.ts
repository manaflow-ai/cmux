// What a fenced block holds, read once per card render (its callers memoize on the code): whether it
// is unlabeled (no language, or `text`), and whether it is a diagram drawn in box-drawing characters
// (├─ └─ │), which draws plain at the font's own line height so its connectors meet.

/// The Unicode box-drawing block, U+2500–U+257F.
const BOX_DRAWING = /[\u2500-\u257f]/;

/** A fence with no language (Markdown.tsx reads it as `text`) or an explicit plain-text one. */
export const isUnlabeledLang = (lang: string | undefined) => !lang || lang === "text" || lang === "txt";

/** An unlabeled fence that draws boxes: never highlighted or wrapped, lines that touch. */
export const isDiagram = (code: string, lang: string | undefined) => isUnlabeledLang(lang) && BOX_DRAWING.test(code);
