/// `/help`: one searchable sheet of what the composer can do (Leo 2026-11-22: "is there a /help?
/// apparently not. welp. how should we do things?"). Its commands are the `/` list's own (the
/// composer's merged list: cmux's, the harness's, skills, prompts, extensions), so the sheet and the
/// list never disagree; its keys are the composer's keyboard (Composer.tsx `keyDown`) as one table
/// here, and the host-bound shortcuts (shortcuts.ts) with the keycaps the host pushes.

import type { StringKey, Translate } from "./i18n";
import { SHORTCUT_ACTIONS, type ShortcutLabels } from "./shortcuts";
import { shownName, type SlashCommand } from "./slashCommands";

export type HelpSection = "commands" | "skills" | "keys";

export type HelpRow =
  | {
      kind: "command";
      id: string;
      section: "commands" | "skills";
      /** `/name`, as the `/` list shows it. */
      title: string;
      hint?: string;
      detail: string;
      /** Where it comes from, one word (Skill, Prompt, an extension's name); none for the agent's and cmux's. */
      tag?: string;
      command: SlashCommand;
    }
  | { kind: "key"; id: string; section: "keys"; title: string; keys: string };

/// The composer's own keys, in the order a person meets them. Each is handled in Composer.tsx
/// (`keyDown`, the `/` `@` `:` triggers, shell mode) or the field (Shift-Return); a key moved there
/// moves here. `keys` are the Mac's keycaps, space-separated for a sequence.
export const COMPOSER_KEYS: readonly { id: string; label: StringKey; keys: string }[] = [
  { id: "send", label: "help.key.send", keys: "↩" },
  { id: "newline", label: "help.key.newline", keys: "⇧↩" },
  { id: "queue", label: "help.key.queue", keys: "⌘↩" },
  { id: "newline-option", label: "help.key.newline", keys: "⌥↩" },
  { id: "suggestion", label: "help.key.suggestion", keys: "⇥" },
  { id: "stop", label: "help.key.stop", keys: "esc esc" },
  { id: "history", label: "help.key.history", keys: "↑ ↓" },
  { id: "commands", label: "help.key.commands", keys: "/" },
  { id: "mention", label: "help.key.mention", keys: "@" },
  { id: "emoji", label: "help.key.emoji", keys: ":" },
  { id: "shell", label: "help.key.shell", keys: "!" },
  { id: "attach", label: "help.key.attach", keys: "⌘V" },
];

/// The host-bound composer actions the sheet lists when the host gave them a keycap (an action
/// with none is left out rather than shown without its key).
const BOUND: readonly { action: string; label: StringKey }[] = [
  { action: SHORTCUT_ACTIONS.composerAddMenu, label: "composer.add" },
  { action: SHORTCUT_ACTIONS.switchModel, label: "picker.model" },
  { action: SHORTCUT_ACTIONS.composerTogglePlan, label: "picker.plan" },
  { action: SHORTCUT_ACTIONS.composerChooseFolder, label: "help.key.folder" },
  { action: SHORTCUT_ACTIONS.composerShowContextUsage, label: "composer.slashContext" },
  { action: SHORTCUT_ACTIONS.toggleDictation, label: "help.key.dictation" },
  { action: SHORTCUT_ACTIONS.newAgentChat, label: "help.key.newChat" },
];

const describe = (command: SlashCommand, t: Translate) =>
  command.descriptionKey ? t(command.descriptionKey) : command.description;

const tagOf = (command: SlashCommand, t: Translate) =>
  command.source === "skill"
    ? t("composer.slashSkill")
    : command.source === "prompt"
      ? t("composer.slashPrompt")
      : command.source === "extension"
        ? (command.extension ?? "cmux")
        : undefined;

/// Every row of the sheet, before a search: the commands (cmux's and the agent's), then skills and
/// prompts, then the keys. One pass over the commands; `/help` itself is left out.
export function helpRows(
  commands: readonly SlashCommand[] | undefined,
  shortcuts: ShortcutLabels,
  t: Translate,
): HelpRow[] {
  const ran: HelpRow[] = [];
  const skills: HelpRow[] = [];
  const seen = new Set<string>();
  for (const command of commands ?? []) {
    const name = shownName(command);
    const key = `${command.source ?? "agent"}:${name}`;
    if (command.name === "help" || seen.has(key)) continue;
    seen.add(key);
    const skill = command.source === "skill" || command.source === "prompt";
    const tag = tagOf(command, t);
    (skill ? skills : ran).push({
      kind: "command",
      id: `command:${key}`,
      section: skill ? "skills" : "commands",
      title: `/${name}`,
      ...(command.hint ? { hint: command.hint } : {}),
      detail: describe(command, t),
      ...(tag ? { tag } : {}),
      command,
    });
  }
  const keys: HelpRow[] = COMPOSER_KEYS.map((key) => ({
    kind: "key",
    id: `key:${key.id}`,
    section: "keys",
    title: t(key.label),
    keys: key.keys,
  }));
  for (const bound of BOUND) {
    const keycap = shortcuts[bound.action];
    if (keycap)
      keys.push({ kind: "key", id: `key:${bound.action}`, section: "keys", title: t(bound.label), keys: keycap });
  }
  return [...ran, ...skills, ...keys];
}

/// The rows a search keeps: every word of `query` in the row's name, argument, description, tag or
/// keys, case-insensitive. An empty query keeps all.
export function searchHelp(rows: readonly HelpRow[], query: string): HelpRow[] {
  const words = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [...rows];
  return rows.filter((row) => {
    const text = (
      row.kind === "command"
        ? `${row.title} ${row.hint ?? ""} ${row.detail} ${row.tag ?? ""}`
        : `${row.title} ${row.keys}`
    ).toLocaleLowerCase();
    return words.every((word) => text.includes(word.replace(/^\//, "")));
  });
}

/// The section labels, in order.
export const HELP_SECTIONS: readonly { id: HelpSection; label: StringKey }[] = [
  { id: "commands", label: "help.section.commands" },
  { id: "skills", label: "help.section.skills" },
  { id: "keys", label: "help.section.keys" },
];
