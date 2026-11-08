// The chat's skills for its sent prompts (UserBubble.tsx, PromptText.tsx, ComposerQueue.tsx): a
// prompt went with a Codex skill as `/$name` (slashCommands.ts withSkillDollars) and reads `/name`
// again, but only for a name the chat's command list has as a skill; and each `/name` of a skill or
// prompt in the list draws in the command words' blue, its description on hover. A context, so a new
// list reaches memoized rows.
import { createContext, useRef } from "react";
import {
  commandWords,
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
};

const NONE: SkillWords = { dollar: new Set(), plain: new Set(), words: new Map() };

export const SkillWordsContext = createContext<SkillWords>(NONE);

export function skillWords(commands: readonly SlashCommand[] | undefined): SkillWords {
  if (!commands?.length) return NONE;
  const words = new Map<string, string>();
  for (const command of commands) if (goesAsText(command)) words.set(shownName(command), command.description.trim());
  return { ...skillCatalog(commands), words };
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

/// `text` cut at each `/name` of a skill in `words`, as send and the display mapping read a command
/// word (slashCommands.ts commandWords): never in Markdown code. One pass.
export function splitSkillWords(text: string, words: ReadonlyMap<string, string>): SkillPiece[] {
  if (!words.size || !text.includes("/")) return [text];
  const pieces: SkillPiece[] = [];
  let last = 0;
  for (const { start, end, word } of commandWords(text)) {
    const description = words.get(word);
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
