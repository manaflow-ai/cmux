// The composer's + menu, one component for the chat composer and the New Tab composer (Leo,
// 2026-10-31: "our + button is ass" / "inside chat and in the composer it's ass"). Its reference is
// ChatGPT's + menu: a short list in groups (attach first, then the composer's own actions, then the
// searches, then the host's catalog groups), one row per action with an icon, a title and a muted
// description on one line, in a bounded panel that scrolls inside. Skills and commands are never
// listed whole here (Leo, 2026-11-01: "our + button results are still really bad"): at most a few
// recent ones, then one "Commands and skills…" row that opens the slash list, which searches them
// all (composerPlusRegistry.ts, recentCommands.ts).
import { useCallback, useState } from "react";

import { Picker, PlusIcon, type Section } from "./ComposerPickers";
import { runComposerPlusAction, type ComposerPlusEntry } from "./composerPlusRegistry";
import type { SlashCommand } from "./slashCommands";
import { useT } from "./i18n";

import { experimentArm } from "../../experiments/experiment";
import { composerPlusCommands } from "./composerPlusCommands.experiment";
import { composerPlusMenuSections } from "./composerPlusMenuModel";

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
  // A picked row's action can change the rows (an attached screenshot takes away Run on several
  // agents): the closing menu keeps the rows it was picked from, so none drops out under the
  // pointer and the rows below it don't jump; the next open lists the composer's rows again.
  const [held, setHeld] = useState<readonly ComposerPlusEntry[] | null>(null);
  const opened = useCallback(() => {
    setHeld(null);
    onOpen?.();
  }, [onOpen]);
  const shown = held ?? entries;
  // Untitled groups: a hairline splits them (styles.css), with no header band between.
  const sections: Section[] = composerPlusMenuSections(shown, planning, experimentArm(composerPlusCommands)).map(
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
        if (handled) setHeld(shown);
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
      sections={sections}
      onOpen={opened}
    />
  );
}
