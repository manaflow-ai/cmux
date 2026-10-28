import { composerPlusRegistry } from "../composerPlusRegistry";
import type { Translate } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import type { SlashCommand } from "../slashCommands";

/** The selected, advertised harness and location; the host binds deferred startup to this pick. */
export type NewTabPlusTarget = { harness: string; cwd?: string; model?: string; peer?: string; noProject?: true };
export type NewTabPlusModePick = NewTabPlusTarget & { modeId: string };

/** Never borrow a previous harness or machine's commands while its replacement is loading. */
export function newTabPlusEntries(options: {
  snapshot: AcpmuxSnapshot;
  target?: NewTabPlusTarget;
  translate: Translate;
  capture: boolean;
  project: boolean;
  mode: boolean;
  commands?: boolean;
}) {
  const { snapshot, target, translate: t } = options;
  const summary = snapshot.summary;
  const bound = Boolean(
    target &&
    summary?.harness === target.harness &&
    summary?.peer === target.peer &&
    (!target.cwd || summary?.cwd === target.cwd),
  );
  const modes = bound ? summary?.modes : undefined;
  const plan = modes?.availableModes.find((mode) => /(^|[-_])plan$/i.test(mode.id));
  const planning = plan?.id === modes?.currentModeId;
  const nextMode = planning ? modes?.availableModes.find((mode) => !/(^|[-_])plan$/i.test(mode.id)) : plan;
  return composerPlusRegistry({
    translate: t,
    canCapture: options.capture && summary?.promptCapabilities?.image !== false,
    canChooseProject: options.project,
    commands: bound && options.commands !== false ? snapshot.commands : undefined,
    ...(options.mode && nextMode
      ? {
          planMode: {
            id: nextMode.id,
            name: t(planning ? "picker.build" : "picker.plan"),
            description: t("picker.planHint"),
          },
        }
      : {}),
  }).filter((entry) => entry.section === "add" && entry.id !== "add.mention" && entry.id !== "add.commands");
}

/** + actions apply to the full draft, including inline attachment markers, not a slash-query slice. */
export function newTabCommandDraft(command: SlashCommand, draft: string): string {
  return `/${command.name} ${draft}`;
}
