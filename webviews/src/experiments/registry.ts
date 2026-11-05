// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item).
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import { diffTreeDisclosure, treeNameFade } from "../agent-session/acpmux/changes/treeMotion.experiment";
import { sessionReplay } from "../agent-session/acpmux/replay/replay.experiment";
import { chiefDock } from "../agent-session/acpmux/chiefDock.experiment";
import { newTabHeadline } from "../agent-session/acpmux/newtab/headline.experiment";
import { newTabComposerTrailingGap } from "../agent-session/acpmux/newtab/composerGap.experiment";
import { hoverActions } from "../ui/hoverActions.experiment";
import { toolErrorLook } from "../agent-session/acpmux/conversation/toolError.experiment";
import { backgroundReactionLook } from "../agent-session/acpmux/conversation/backgroundReaction.experiment";
import { cloudStartLook } from "../agent-session/acpmux/cloudStart.experiment";
import { agentStartLook } from "../agent-session/acpmux/conversation/agentStart.experiment";
import { liveLineTokens } from "../agent-session/acpmux/conversation/liveLineTokens.experiment";
import { threadMinimapLayout } from "../agent-session/acpmux/threadMinimap/layout.experiment";
import { threadMinimapHeight } from "../agent-session/acpmux/threadMinimap/height.experiment";
import { threadMinimapGutter } from "../agent-session/acpmux/threadMinimap/gutter.experiment";
import { threadMinimapLit } from "../agent-session/acpmux/threadMinimap/lit.experiment";
import { threadMinimapMark } from "../agent-session/acpmux/threadMinimap/mark.experiment";
import { threadMinimapWave } from "../agent-session/acpmux/threadMinimap/wave.experiment";
import { threadMinimapIncoming } from "../agent-session/acpmux/threadMinimap/incoming.experiment";
import { chatMinimapPlaceholder } from "../agent-session/acpmux/chatMinimap/placeholder.experiment";
import { startedSessionCards } from "../agent-session/acpmux/started/startedSessions.experiment";
import { finishedTaskLook } from "../agent-session/acpmux/conversation/taskLine.experiment";
import { toolActivityPresentation } from "../agent-session/acpmux/conversation/toolActivityPresentation.experiment";
import { claudeTurnFold } from "../agent-session/acpmux/conversation/claudeTurnFold.experiment";
import { turnErrorCard } from "../agent-session/acpmux/conversation/turnErrorCard.experiment";
import { pausedMachineResume } from "../agent-session/acpmux/pausedMachine.experiment";
import { codeRouterOffer } from "../agent-session/acpmux/conversation/codeRouterOffer.experiment";
import { stoppedTurnLook } from "../agent-session/acpmux/conversation/stoppedTurn.experiment";
import { chromiumGlassUnderlay } from "../ui/glass/chromiumUnderlay.experiment";
import { questionPreviewLayout } from "../agent-session/acpmux/question/previewLayout.experiment";
import { trayPanelLook, trayRowLook, trayStopLook } from "../agent-session/acpmux/subagents/trayPanel.experiment";
import { trayMotionLook } from "../agent-session/acpmux/subagents/trayMotion.experiment";
import { trayHeadLook } from "../agent-session/acpmux/subagents/trayHead.experiment";
import { trayFoldHeadLook } from "../agent-session/acpmux/subagents/trayFoldHead.experiment";
import { trayKindLineLook } from "../agent-session/acpmux/subagents/trayKindLine.experiment";
import { trayHeadKindsLook } from "../agent-session/acpmux/subagents/trayHeadKinds.experiment";
import { trayOpenLook } from "../agent-session/acpmux/subagents/trayOpen.experiment";
import { failedLineLook } from "../agent-session/acpmux/subagents/failedLine.experiment";
import { trayLatestLook } from "../agent-session/acpmux/subagents/trayLatest.experiment";
import { doneReportLook } from "../agent-session/acpmux/subagents/doneReport.experiment";
import { traySurfaceLook } from "../agent-session/acpmux/subagents/traySurface.experiment";
import { chatSwitchMotion } from "../agent-session/acpmux/chatSwitch.experiment";
import { liveBackground } from "../ui/liveBackground/liveBackground.experiment";
import { composerPlusCommands } from "../agent-session/acpmux/composerPlusCommands.experiment";
import { promptSuggestionLook } from "../agent-session/acpmux/promptSuggestionLook.experiment";
import { contextRingLook } from "../agent-session/acpmux/contextRingLook.experiment";
import { planUsageLook } from "../agent-session/acpmux/planUsageLook.experiment";
import { emojiShortcodeLook } from "../agent-session/acpmux/emojiShortcodeLook.experiment";
import { fileKindIcon } from "../agent-session/acpmux/chips/fileKindIcon.experiment";
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [
  diffTreeDisclosure,
  treeNameFade,
  sessionReplay,
  chiefDock,
  hoverActions,
  startedSessionCards,
  fileKindIcon,
  finishedTaskLook,
  claudeTurnFold,
  toolActivityPresentation,
  threadMinimapLayout,
  threadMinimapHeight,
  threadMinimapGutter,
  newTabHeadline,
  newTabComposerTrailingGap,
  threadMinimapLit,
  threadMinimapMark,
  threadMinimapWave,
  threadMinimapIncoming,
  chatMinimapPlaceholder,
  turnErrorCard,
  pausedMachineResume,
  codeRouterOffer,
  stoppedTurnLook,
  chromiumGlassUnderlay,
  questionPreviewLayout,
  toolErrorLook,
  backgroundReactionLook,
  cloudStartLook,
  agentStartLook,
  liveLineTokens,
  trayPanelLook,
  trayRowLook,
  trayStopLook,
  trayMotionLook,
  trayHeadLook,
  trayFoldHeadLook,
  trayHeadKindsLook,
  trayKindLineLook,
  trayOpenLook,
  failedLineLook,
  trayLatestLook,
  doneReportLook,
  traySurfaceLook,
  chatSwitchMotion,
  liveBackground,
  composerPlusCommands,
  promptSuggestionLook,
  contextRingLook,
  planUsageLook,
  emojiShortcodeLook,
];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
