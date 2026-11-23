// The composer's + menu, one component for the chat composer and the New Tab composer (Leo,
// 2026-10-31: "our + button is ass" / "inside chat and in the composer it's ass"). Its reference is
// ChatGPT's + menu: a short list in groups (attach first, then the composer's own actions, then the
// searches, then the host's catalog groups), one row per action with an icon, a title and a muted
// description on one line, in a bounded panel that scrolls inside. Skills and commands are never
// listed whole here (Leo, 2026-11-01: "our + button results are still really bad"): at most a few
// recent ones, then one "Commands and skills…" row that opens the slash list, which searches them
// all (composerPlusRegistry.ts, recentCommands.ts).
import { SHORTCUT_ACTIONS, useShortcut } from "./shortcuts";
import { PaperclipIcon, Picker, ComposerPlusIcon, type Section } from "./ComposerPickers";
import { runComposerPlusAction, type ComposerPlusEntry, isComposerCommand } from "./composerPlusRegistry";
import type { SlashCommand } from "./slashCommands";
import { useT } from "./i18n";

import { experimentArm } from "../../experiments/experiment";
import { composerPlusCommands } from "./composerPlusCommands.experiment";
import type { PageClient } from "../../pages/shared/pageClient";
import { Tooltip } from "../../ui/Tooltip";
import { Button } from "../../ui/Button";
import { useComposerContribution } from "./composer/extensionCommands";
import { toolbarButtonsFrom, type ToolbarButton } from "./composer/toolbarButtons";
import { composerPlusMenuSections, composerActionIcon } from "./composerPlusMenuModel";
import { acpmuxPerf } from "./perf";
import { useStableHandlers } from "./stableHandlers";
import { memo, useEffect } from "react";
import { PLAN_TOGGLE_OPENER } from "./composerControls";
import { registerPicker } from "./pickerOpeners";

const NO_BUTTONS: readonly ToolbarButton[] = [];

export type ComposerPlusMenuProps = {
  /** The rows, from composerPlusRegistry, already narrowed to what this composer can run. */
  entries: readonly ComposerPlusEntry[];
  client?: PageClient | null;
  /** The trigger's extra classes (New Tab's `acpmux-newtab-plus`). */
  className?: string;
  /** The trigger's glyph: + (the default), or Studio's attach paperclip at the row's right end, its menu opening leftward. */
  glyph?: "plus" | "paperclip";
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

/// The + menu draws again only when its rows or Plan change, never on a keystroke in the composer
/// (CMUX-571; Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference").
/// The composer builds its handlers inline on each render, so each `on*` prop is one stable function
/// that calls the latest (useStableHandlers), and the composer memoizes `entries`.
export function ComposerPlusMenu(props: ComposerPlusMenuProps) {
  return <MemoPlusMenu {...useStableHandlers(props)} />;
}

const MemoPlusMenu = memo(function PlusMenu({
  entries,
  className,
  glyph = "plus",
  client,
  planning = false,
  onCommand,
  onExtension,
  onSlash,
  onOpen,
}: ComposerPlusMenuProps) {
  acpmuxPerf.render("composer:plus");
  const t = useT();
  const addShortcut = useShortcut(SHORTCUT_ACTIONS.composerAddMenu);
  const planShortcut = useShortcut(SHORTCUT_ACTIONS.composerTogglePlan);
  // Toggle Plan Mode (composerControls.ts) runs the Plan/Build row's own action, the path a click
  // on the row takes: the app draws no Plan toggle chip, so this row owns the key. The opener is
  // registered again with each row and handler, never through useEffectEvent: React 19.2.3 updates
  // an effect event only in a plain function component, and this memo component kept its first
  // render's, drawn before a new chat's agent reported its modes (test/composer-plan-key.test.tsx).
  const planEntry = entries.find((entry) => entry.id.startsWith("add.mode."));
  useEffect(
    () =>
      planEntry
        ? registerPicker(PLAN_TOGGLE_OPENER, () =>
            runComposerPlusAction(planEntry.action, { command: onCommand, slash: onSlash }),
          )
        : undefined,
    [planEntry, onCommand, onSlash],
  );
  const buttons = useComposerContribution<readonly ToolbarButton[]>(toolbarButtonsFrom, NO_BUTTONS, client);
  const handlers = { command: onCommand, extension: onExtension, slash: onSlash };
  // Untitled groups: a hairline splits them (styles.css), with no header band between.
  const sections: Section[] = composerPlusMenuSections(
    entries,
    planning,
    experimentArm(composerPlusCommands),
    planShortcut,
  ).map((group) => ({
    choices: group.choices,
    onPick: (id: string) => {
      const entry = group.entries.find((row) => row.id === id);
      if (!entry) return "keep";
      const handled = runComposerPlusAction(entry.action, handlers);
      return handled ? undefined : "keep";
    },
  }));
  const plus = (
    <Picker
      label={t("composer.add")}
      // Claude Code's one-word tooltip (Leo 2026-11-23: the more minimal Claude Code composer is favoured).
      tooltip={t("composer.add")}
      shortcut={addShortcut}
      className={className ? `acpmux-composer-plus ${className}` : "acpmux-composer-plus"}
      button={glyph === "paperclip" ? <PaperclipIcon /> : <ComposerPlusIcon />}
      align={glyph === "paperclip" ? "end" : "start"}
      sections={sections}
      {...(onOpen ? { onOpen } : {})}
    />
  );
  const available = buttons.flatMap(({ action, label }) => {
    const entry = entries.find((row) => row.action.kind === "command" && row.action.id === action);
    if (!entry || (!onExtension && !isComposerCommand(action))) return [];
    const title = label ?? entry.name;
    return [
      <Tooltip key={action} label={title}>
        <Button
          size="sm"
          variant="ghost"
          icon
          aria-label={title}
          onClick={() => runComposerPlusAction(entry.action, handlers)}
        >
          {composerActionIcon(entry, planning)}
        </Button>
      </Tooltip>,
    ];
  });
  if (!available.length) return plus;
  return (
    <span className="acpmux-composer-extension-tools">
      {plus}
      <span className="acpmux-composer-extension-buttons">{available}</span>
    </span>
  );
});
