// The chat's skills for its sent prompts (UserBubble.tsx, PromptText.tsx, ComposerQueue.tsx): a
// prompt went with a Codex skill as `/$name` (slashCommands.ts withSkillDollars) and reads `/name`
// again, but only for a name the chat's command list has as a skill; and each `/name` of a skill or
// prompt in the list draws in the command words' blue, its description on hover. A context, so a new
// list reaches memoized rows. The prompt's first word lights for any command of the list, as the
// composer lights it there (slashCommands.ts slashNames `leading`): a sent `/compact` or `/goal ship
// it` keeps the rendering it had in the composer (Leo 2026-11-09).
import { createContext, useRef } from "react";
import {
  commandWords,
  promptStart,
  goesAsText,
  shownName,
  skillCatalog,
  type SkillCatalog,
  type SlashCommand,
} from "../slashCommands";

export type SkillWords = SkillCatalog & {
  /// Each skill's and prompt's shown name (`/emil-color` for `$emil-color`), and its description
  /// ("" when the list gives none).
  words: ReadonlyMap<string, string>;
  /// Every command's shown name, a word that is a command only as the prompt's first word (the
  /// composer's `leading`), with the description its word shows: a skill's or prompt's, else "" (the
  /// composer gives a built-in none either).
  leading: ReadonlyMap<string, string>;
};

const NONE: SkillWords = { dollar: new Set(), plain: new Set(), words: new Map(), leading: new Map() };

export const SkillWordsContext = createContext<SkillWords>(NONE);

export function skillWords(commands: readonly SlashCommand[] | undefined): SkillWords {
  if (!commands?.length) return NONE;
  const words = new Map<string, string>();
  const leading = new Map<string, string>();
  for (const command of commands) {
    const description = goesAsText(command) ? command.description.trim() : "";
    if (goesAsText(command)) words.set(shownName(command), description);
    // A skill and a built-in of one shown name: the skill's description, as the composer's tooltip.
    if (goesAsText(command) || !leading.has(shownName(command))) leading.set(shownName(command), description);
  }
  return { ...skillCatalog(commands), words, leading };
}

/// The skill words of `commands`, the same object while their names, kinds and descriptions are the
/// same: a chat's snapshot rebuilds its list on every update.
export function useSkillWords(commands: readonly SlashCommand[] | undefined): SkillWords {
  const key = (commands ?? [])
    .map((command) => `${command.name}\u0000${command.source ?? ""}\u0000${command.description}`)
    .join("\n");
  const kept = useRef<{ key: string; words: SkillWords }>(undefined);
  if (kept.current?.key !== key) kept.current = { key, words: skillWords(commands) };
  return kept.current.words;
}

/// A piece of a prompt's text: its own text, or a skill word with its description.
export type SkillPiece = string | { word: string; description: string };

/// The command a prompt starts with, as the composer reads its first word: the `/name` at the prompt's
/// start (past spaces, line breaks and placed attachments), outside code, that names a command of
/// `leading`. Undefined when the prompt starts with anything else.
export function leadCommand(
  text: string,
  leading: ReadonlyMap<string, string> | undefined,
): { start: number; word: string; description: string } | undefined {
  if (!leading?.size || !text.includes("/")) return undefined;
  const start = promptStart(text);
  if (text[start] !== "/") return undefined;
  // Only the first word is read: nothing before it can open code, so it alone decides.
  const space = /[\s\uFFFC]/g;
  space.lastIndex = start;
  const end = space.exec(text)?.index ?? text.length;
  const first = commandWords(text.slice(0, end)).find((word) => word.start === start);
  if (!first) return undefined;
  const description = leading.get(first.word);
  return description === undefined ? undefined : { start, word: first.word, description };
}

/// `text` cut at each `/name` of a skill in `words`, as send and the display mapping read a command
/// word (slashCommands.ts commandWords): never in Markdown code. With `leading`, the prompt's first
/// word is cut too when it names any command (`leadCommand`). One pass.
export function splitSkillWords(
  text: string,
  words: ReadonlyMap<string, string>,
  leading?: ReadonlyMap<string, string>,
): SkillPiece[] {
  if ((!words.size && !leading?.size) || !text.includes("/")) return [text];
  const lead = leadCommand(text, leading);
  const pieces: SkillPiece[] = [];
  let last = 0;
  for (const { start, end, word } of commandWords(text)) {
    const description = start === lead?.start ? lead.description : words.get(word);
    if (description === undefined) continue;
    if (start > last) pieces.push(text.slice(last, start));
    pieces.push({ word: `/${word}`, description });
    last = end;
  }
  if (!pieces.length) return [text];
  if (last < text.length) pieces.push(text.slice(last));
  return pieces;
}

/// `text`, a run of plain text the transcript's Markdown renderer produced (never code: the
/// renderer took code out with the same reading send uses, slashCommands.ts), cut at each `/name` of
/// a skill in `words` in a command position. Markdown.tsx `skills` draws these.
export function splitSkillText(text: string, words: ReadonlyMap<string, string>): SkillPiece[] {
  if (!words.size || !text.includes("/")) return [text];
  const pieces: SkillPiece[] = [];
  let last = 0;
  for (const found of text.matchAll(/(^|[\s\uFFFC])\/([^\s\uFFFC]+)(?=[\s\uFFFC]|$)/g)) {
    const description = words.get(found[2]!);
    if (description === undefined) continue;
    const start = found.index! + found[1]!.length;
    if (start > last) pieces.push(text.slice(last, start));
    pieces.push({ word: `/${found[2]!}`, description });
    last = start + found[2]!.length + 1;
  }
  if (!pieces.length) return [text];
  if (last < text.length) pieces.push(text.slice(last));
  return pieces;
}
