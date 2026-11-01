// The chat's Codex skills for its sent prompts (UserBubble.tsx, ComposerQueue.tsx): a prompt went
// with `/$name` (slashCommands.ts withSkillDollars) and reads `/name` again, but only for a name the
// chat's command list has as a skill. A context, so a new list reaches memoized rows.
import { createContext, useRef } from "react";
import { skillCatalog, type SkillCatalog, type SlashCommand } from "../slashCommands";

export type SkillWords = SkillCatalog;

const NONE: SkillWords = { dollar: new Set(), plain: new Set() };

export const SkillWordsContext = createContext<SkillWords>(NONE);

/// The catalog of `commands`, the same object while their names are the same: a chat's snapshot
/// rebuilds its list on every update.
export function useSkillWords(commands: readonly SlashCommand[] | undefined): SkillWords {
  const key = (commands ?? []).map((command) => command.name).join("\n");
  const kept = useRef<{ key: string; words: SkillWords }>(undefined);
  if (kept.current?.key !== key) kept.current = { key, words: key ? skillCatalog(commands) : NONE };
  return kept.current.words;
}
