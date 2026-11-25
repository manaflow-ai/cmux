// The one case fold every find uses, so a find cannot lowercase on its own and drift from the
// others (test/find-fold-guard.test.ts fails a find module that does).

/** The text a find compares: case-folded, and as long as it was, so a match's offset in the folded
 * text is its offset in what the page draws. `İ` (U+0130) lowercases to two code units (`i` and a
 * combining dot), which moves every highlight after it one character and makes a plain `i` query
 * miss it; it folds to `i` instead. `toLowerCase` and not `toLocaleLowerCase`, whose result follows
 * the host's locale (Lithuanian expands more letters, Turkish folds `I` to `ı`): a query matches the
 * same text on every machine. */
export const foldFind = (text: string): string => text.replace(/\u0130/g, "i").toLowerCase();
