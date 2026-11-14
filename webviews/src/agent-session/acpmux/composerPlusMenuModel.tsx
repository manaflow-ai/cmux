import type React from "react";
import { AtIcon, BuildIcon, PaperclipIcon, PlanIcon, SearchIcon, SlashIcon } from "./ComposerPickers";
import { type Choice } from "./composerPickerModel";
import { composerPlusSections, type ComposerPlusEntry, type ComposerPlusSection } from "./composerPlusRegistry";
import { Icon } from "./icons/Icon";
import { composerPlusCommands } from "./composerPlusCommands.experiment";

function rowIcon(entry: ComposerPlusEntry, planning: boolean): React.ReactNode {
  if (entry.id === "add.files") return <PaperclipIcon />;
  if (entry.id === "add.mention") return <AtIcon />;
  if (entry.id === "add.commands") return <SlashIcon />;
  // icon-scale-allow: the composer's own 18 glyph set (design/grid.md)
  if (entry.id === "files.search") return <SearchIcon size={18} />;
  if (entry.id.startsWith("add.mode.")) return planning ? <BuildIcon /> : <PlanIcon />;
  // icon-scale-allow: the composer's own 18 glyph set (design/grid.md)
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
