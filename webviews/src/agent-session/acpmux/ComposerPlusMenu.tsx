// The composer's + menu, one component for the chat composer and the New Tab composer (Leo,
// 2026-10-31: "our + button is ass" / "inside chat and in the composer it's ass"). Its reference is
// ChatGPT's + menu: a short list in groups (attach first, then the composer's own actions, then the
// searches, then the host's catalog groups), one row per action with an icon, a title and a muted
// description on one line, in a bounded panel that scrolls inside. Skills and commands are never
// listed whole here (Leo, 2026-11-01: "our + button results are still really bad"): at most a few
// recent ones, then one "Commands and skills…" row that opens the slash list, which searches them
// all (composerPlusRegistry.ts, recentCommands.ts).
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
import { experimentArm } from "../../experiments/experiment";
import { composerPlusCommands } from "./composerPlusCommands.experiment";

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
  /** A slash command row (Goal, a recent command): it writes the command over the draft. */
  onSlash(command: SlashCommand): void;
  /** The menu opens: the composer reads its recent commands again (another pane may have used one). */
  onOpen?(): void;
};

function rowIcon(entry: ComposerPlusEntry, planning: boolean): React.ReactNode {
  if (entry.id === "add.files") return <PaperclipIcon />;
  if (entry.id === "add.mention") return <AtIcon />;
  if (entry.id === "add.commands") return <SlashIcon />;
  if (entry.id === "files.search") return <SearchIcon size={18} />;
  if (entry.id.startsWith("add.mode.")) return planning ? <BuildIcon /> : <PlanIcon />;
  return <Icon name={entry.icon} size={18} />;
}

export type ComposerPlusCommandsArm = keyof typeof composerPlusCommands.arms;

/** The commands group as the arm draws it: recents then the row (shipped), the row first, or the row alone. */
function arrangeCommands(rows: ComposerPlusEntry[], arm: ComposerPlusCommandsArm): ComposerPlusEntry[] {
  const recents = rows.filter((entry) => entry.id !== "add.commands");
  const row = rows.filter((entry) => entry.id === "add.commands");
  if (arm === "row-only") return row.length ? row : recents;
  return arm === "row-then-recents" ? [...row, ...recents] : [...recents, ...row];
}

/** The groups the menu draws, in COMPOSER_PLUS_SECTIONS order, empty ones left out. */
export function composerPlusMenuSections(
  entries: readonly ComposerPlusEntry[],
  planning = false,
  arm: ComposerPlusCommandsArm = composerPlusCommands.defaultArm,
): { section: ComposerPlusSection; entries: ComposerPlusEntry[]; choices: Choice[] }[] {
  return [...composerPlusSections(entries)].flatMap(([section, all]) => {
    const rows = section === "commands" ? arrangeCommands(all, arm) : all;
    return rows.length
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
      : [];
  });
}

export function ComposerPlusMenu({
  entries,
  className,
  planning = false,
  onCommand,
  onExtension,
  onSlash,
  onOpen,
}: ComposerPlusMenuProps) {
  const t = useT();
  // Untitled groups: a hairline splits them (styles.css), with no header band between.
  const sections: Section[] = composerPlusMenuSections(entries, planning, experimentArm(composerPlusCommands)).map(
    (group) => ({
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
    }),
  );
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
      {...(onOpen ? { onOpen } : {})}
    />
  );
}
