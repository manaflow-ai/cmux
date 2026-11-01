// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item).
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import { diffTreeDisclosure, treeNameFade } from "../agent-session/acpmux/changes/treeMotion.experiment";
import { sessionReplay } from "../agent-session/acpmux/replay/replay.experiment";
import { chiefDock } from "../agent-session/acpmux/chiefDock.experiment";
import { newTabHeadline } from "../agent-session/acpmux/newtab/headline.experiment";
import { hoverActions } from "../ui/hoverActions.experiment";
import { toolErrorLook } from "../agent-session/acpmux/conversation/toolError.experiment";
import { cloudStartLook } from "../agent-session/acpmux/cloudStart.experiment";
import { threadMinimapLayout } from "../agent-session/acpmux/threadMinimap/layout.experiment";
import { threadMinimapHeight } from "../agent-session/acpmux/threadMinimap/height.experiment";
import { threadMinimapGutter } from "../agent-session/acpmux/threadMinimap/gutter.experiment";
import { threadMinimapLit } from "../agent-session/acpmux/threadMinimap/lit.experiment";
import { threadMinimapMark } from "../agent-session/acpmux/threadMinimap/mark.experiment";
import { chatMinimapPlaceholder } from "../agent-session/acpmux/chatMinimap/placeholder.experiment";
import { startedSessionCards } from "../agent-session/acpmux/started/startedSessions.experiment";
import { turnErrorCard } from "../agent-session/acpmux/conversation/turnErrorCard.experiment";
import { pausedMachineResume } from "../agent-session/acpmux/pausedMachine.experiment";
import { codeRouterOffer } from "../agent-session/acpmux/conversation/codeRouterOffer.experiment";
import { chromiumGlassUnderlay } from "../ui/glass/chromiumUnderlay.experiment";
import { questionPreviewLayout } from "../agent-session/acpmux/question/previewLayout.experiment";
import { trayPanelLook, trayRowLook } from "../agent-session/acpmux/subagents/trayPanel.experiment";
import { trayMotionLook } from "../agent-session/acpmux/subagents/trayMotion.experiment";
import { trayHeadLook } from "../agent-session/acpmux/subagents/trayHead.experiment";
import { liveBackground } from "../ui/liveBackground/liveBackground.experiment";
import { composerPlusCommands } from "../agent-session/acpmux/composerPlusCommands.experiment";
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [
  diffTreeDisclosure,
  treeNameFade,
  sessionReplay,
  chiefDock,
  hoverActions,
  startedSessionCards,
  threadMinimapLayout,
  threadMinimapHeight,
  threadMinimapGutter,
  newTabHeadline,
  threadMinimapLit,
  threadMinimapMark,
  chatMinimapPlaceholder,
  turnErrorCard,
  pausedMachineResume,
  codeRouterOffer,
  chromiumGlassUnderlay,
  questionPreviewLayout,
  toolErrorLook,
  cloudStartLook,
  trayPanelLook,
  trayRowLook,
  trayMotionLook,
  trayHeadLook,
  liveBackground,
  composerPlusCommands,
];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
