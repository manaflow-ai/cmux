// The composer's + menu, one component for the chat composer and the New Tab composer (Leo,
// 2026-10-31: "our + button is ass" / "inside chat and in the composer it's ass"). Its reference is
// ChatGPT's + menu: a short list in groups (attach first, then the composer's own actions, then the
// searches, then the host's catalog groups), one row per action with an icon, a title and a muted
// description on one line, in a bounded panel that scrolls inside. Skills are never rows here: one
// Skills… row opens the slash list, which searches them (composerPlusRegistry.ts).
import type React from "react";
import { AtIcon, BuildIcon, PaperclipIcon, PlanIcon, Picker, PlusIcon, SearchIcon, SlashIcon } from "./ComposerPickers";
import type { Choice, Section } from "./ComposerPickers";
import {
  composerPlusSections,
  runComposerPlusAction,
  type ComposerPlusEntry,
  type ComposerPlusSection,
} from "./composerPlusRegistry";
import type { SlashCommand } from "./slashCommands";
import { useT } from "./i18n";
import { Icon } from "./icons/Icon";

export type ComposerPlusMenuProps = {
  /** The rows, from composerPlusRegistry, already narrowed to what this composer can run. */
  entries: readonly ComposerPlusEntry[];
  /** The trigger's extra classes (New Tab's `acpmux-newtab-plus`). */
  className?: string;
  /** Plan is on: its row draws the Build glyph, as its title says Build. */
  planning?: boolean;
  /** A composer action (`composer.attachFiles`, `composer.planMode`, ...). */
  onCommand(id: string, modeId?: string): void;
  /** A host action (Search chats, Search pages, the catalog's rows); none keeps the menu open. */
  onExtension?(id: string): void;
  /** A slash command row (Goal): it writes the command over the draft. */
  onSlash(command: SlashCommand): void;
};

function rowIcon(entry: ComposerPlusEntry, planning: boolean): React.ReactNode {
  if (entry.id === "add.files") return <PaperclipIcon />;
  if (entry.id === "add.mention") return <AtIcon />;
  if (entry.id === "add.commands") return <SlashIcon />;
  if (entry.id === "files.search") return <SearchIcon size={18} />;
  if (entry.id.startsWith("add.mode.")) return planning ? <BuildIcon /> : <PlanIcon />;
  return <Icon name={entry.icon} size={18} />;
}

/** The groups the menu draws, in COMPOSER_PLUS_SECTIONS order, empty ones left out. */
export function composerPlusMenuSections(
  entries: readonly ComposerPlusEntry[],
  planning = false,
): { section: ComposerPlusSection; entries: ComposerPlusEntry[]; choices: Choice[] }[] {
  return [...composerPlusSections(entries)].flatMap(([section, rows]) =>
    rows.length
      ? [
          {
            section,
            entries: rows,
            choices: rows.map((entry): Choice => ({
              id: entry.id,
              name: entry.name,
              // A description that only repeats the title (Goal) is left out.
              description:
                entry.description.trim() && entry.description.trim() !== entry.name.trim()
                  ? entry.description
                  : undefined,
              icon: rowIcon(entry, planning),
              ...(entry.id === "add.mention" ? { hint: "@" } : {}),
              ...(entry.id === "add.commands" ? { hint: "/" } : {}),
            })),
          },
        ]
      : [],
  );
}

export function ComposerPlusMenu({
  entries,
  className,
  planning = false,
  onCommand,
  onExtension,
  onSlash,
}: ComposerPlusMenuProps) {
  const t = useT();
  // Untitled groups: a hairline splits them (styles.css), with no header band between.
  const sections: Section[] = composerPlusMenuSections(entries, planning).map((group) => ({
    choices: group.choices,
    onPick: (id: string) => {
      const entry = group.entries.find((row) => row.id === id);
      if (!entry) return "keep";
      const handled = runComposerPlusAction(entry.action, {
        command: onCommand,
        ...(onExtension ? { extension: onExtension } : {}),
        slash: onSlash,
      });
      return handled ? undefined : "keep";
    },
  }));
  return (
    <Picker
      label={t("composer.add")}
      // Codex's short tooltip (Leo, 2026-10-21): "Add files and more", not the menu's list.
      tooltip={t("composer.addTooltip")}
      className={className ? `acpmux-composer-plus ${className}` : "acpmux-composer-plus"}
      button={<PlusIcon />}
      align="start"
      returnFocus={false}
      overBackdrop
      sections={sections}
    />
  );
}
