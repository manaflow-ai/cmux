// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item).
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import { diffTreeDisclosure, treeNameFade } from "../agent-session/acpmux/changes/treeMotion.experiment";
import { sessionReplay } from "../agent-session/acpmux/replay/replay.experiment";
import { chiefDock } from "../agent-session/acpmux/chiefDock.experiment";
import { hoverActions } from "../ui/hoverActions.experiment";
import { fileIconColor, projectLanguageIcons } from "../agent-session/acpmux/fileIcons.experiment";
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [
  diffTreeDisclosure,
  treeNameFade,
  sessionReplay,
  chiefDock,
  hoverActions,
  projectLanguageIcons,
  fileIconColor,
];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
