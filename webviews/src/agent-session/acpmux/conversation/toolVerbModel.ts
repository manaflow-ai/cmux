import { type Translate } from "../i18n";

/// A label's verb and the rest, split at its first space ("Ran git status": "Ran", "git status").
/// Undefined when it does not start with a word and a space.
export function splitToolLabel(text: string): { verb: string; subject: string } | undefined {
  // One plain space only: the split draws one, so any other gap would change the words.
  const match = /^(\p{L}+) (\S[\s\S]*)$/u.exec(text);
  return match ? { verb: match[1]!, subject: match[2]! } : undefined;
}

/// Whether the reader's language puts the verb first ("Ran {command}", not "{command} を実行しました"
/// or "{command} ausgeführt"): only then do the rows' first words make a column.
export function verbLeads(t: Translate): boolean {
  return /^\p{L}+ \uE000$/u.test(t("tools.ranCommand", { command: "\uE000" }));
}

/// The verb of a translated line's text before its subject ("Ran " of "Ran {command}"), when it is
/// one word and a space.
export function leadingVerb(before: string): string | undefined {
  return /^(\p{L}+) $/u.exec(before)?.[1];
}

/// Verbs as one CSS string, a verb a line (`\A`), quotes and backslashes escaped.
export function verbsCss(verbs: readonly string[]): string {
  return `"${verbs.map((verb) => verb.replace(/[\\"]/g, (c) => `\\${c}`)).join("\\A ")}"`;
}
