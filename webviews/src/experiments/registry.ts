// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item).
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import { diffTreeDisclosure, treeNameFade } from "../agent-session/acpmux/changes/treeMotion.experiment";
import { sessionReplay } from "../agent-session/acpmux/replay/replay.experiment";
import { steerQueueExperiment } from "../agent-session/acpmux/steerQueue/steerQueue.experiment";
import { chiefDock } from "../agent-session/acpmux/chiefDock.experiment";
import { newTabHeadline } from "../agent-session/acpmux/newtab/headline.experiment";
import { newTabComposerTrailingGap } from "../agent-session/acpmux/newtab/composerGap.experiment";
import { newTabIconColumn } from "../agent-session/acpmux/newtab/iconColumn.experiment";
import { hoverActions } from "../ui/hoverActions.experiment";
import { pastePlaceholderLook } from "../agent-session/acpmux/composer/pastePlaceholder.experiment";
import { toolErrorLook } from "../agent-session/acpmux/conversation/toolError.experiment";
import { tableActionsPlace } from "../agent-session/acpmux/conversation/tableActions.experiment";
import { expandRowLook } from "../agent-session/acpmux/conversation/expandRow.experiment";
import { selectionReplyWrap } from "../agent-session/acpmux/conversation/selectionReplyWrap.experiment";
import { backgroundReactionLook } from "../agent-session/acpmux/conversation/backgroundReaction.experiment";
import { backgroundTurnLook } from "../agent-session/acpmux/conversation/backgroundTurnLook.experiment";
import { cloudStartLook } from "../agent-session/acpmux/cloudStart.experiment";
import { cloudStartComposerLook } from "../agent-session/acpmux/cloudStartComposer.experiment";
import { cloudProgressLook } from "../pages/cloud-progress/cloudProgress.experiment";
import { cloudStartAskLook } from "../agent-session/acpmux/cloudStartAsk.experiment";
import { agentStartLook } from "../agent-session/acpmux/conversation/agentStart.experiment";
import { liveLineTokens } from "../agent-session/acpmux/conversation/liveLineTokens.experiment";
import { compactingLine } from "../agent-session/acpmux/conversation/compactingLine.experiment";
import { liveLineTimes } from "../agent-session/acpmux/conversation/liveLineTimes.experiment";
import { liveTurnClock } from "../agent-session/acpmux/conversation/liveTurnClock.experiment";
import { runScroll } from "../agent-session/acpmux/conversation/runScroll.experiment";
import { oneRowPerCall } from "../agent-session/acpmux/conversation/oneRowPerCall.experiment";
import { backgroundHintRoom } from "../agent-session/acpmux/conversation/backgroundHintRoom.experiment";
import { threadMinimapLayout } from "../agent-session/acpmux/threadMinimap/layout.experiment";
import { threadMinimapHeight } from "../agent-session/acpmux/threadMinimap/height.experiment";
import { threadMinimapGutter } from "../agent-session/acpmux/threadMinimap/gutter.experiment";
import { threadMinimapRestTick } from "../agent-session/acpmux/threadMinimap/restTick.experiment";
import { threadMinimapLit } from "../agent-session/acpmux/threadMinimap/lit.experiment";
import { threadMinimapMark } from "../agent-session/acpmux/threadMinimap/mark.experiment";
import { threadMinimapWave } from "../agent-session/acpmux/threadMinimap/wave.experiment";
import { threadMinimapIncoming } from "../agent-session/acpmux/threadMinimap/incoming.experiment";
import { threadMinimapCard } from "../agent-session/acpmux/threadMinimap/card.experiment";
import { chatMinimapPlaceholder } from "../agent-session/acpmux/chatMinimap/placeholder.experiment";
import { codeActionsLook } from "../agent-session/acpmux/conversation/codeActions.experiment";
import { startedSessionCards } from "../agent-session/acpmux/started/startedSessions.experiment";
import { finishedTaskLook } from "../agent-session/acpmux/conversation/taskLine.experiment";
import { claudeTurnFold } from "../agent-session/acpmux/conversation/claudeTurnFold.experiment";
import { commandLabelLook } from "../agent-session/acpmux/conversation/commandLabel.experiment";
import { liveTurnWork } from "../agent-session/acpmux/conversation/liveTurnWork.experiment";
import { turnFoldReplies } from "../agent-session/acpmux/conversation/turnFoldReplies.experiment";
import { turnFoldSteered } from "../agent-session/acpmux/conversation/turnFoldSteered.experiment";
import { workedForMessages } from "../agent-session/acpmux/conversation/workedForMessages.experiment";
import { turnErrorCard } from "../agent-session/acpmux/conversation/turnErrorCard.experiment";
import { pausedMachineResume } from "../agent-session/acpmux/pausedMachine.experiment";
import { codeRouterOffer } from "../agent-session/acpmux/conversation/codeRouterOffer.experiment";
import { stoppedTurnLook } from "../agent-session/acpmux/conversation/stoppedTurn.experiment";
import { chromiumGlassUnderlay } from "../ui/glass/chromiumUnderlay.experiment";
import { questionPreviewLayout } from "../agent-session/acpmux/question/previewLayout.experiment";
import { trayPanelLook, trayRowLook, trayStopLook } from "../agent-session/acpmux/subagents/trayPanel.experiment";
import { trayMotionLook } from "../agent-session/acpmux/subagents/trayMotion.experiment";
import { composerHatLook } from "../agent-session/acpmux/subagents/composerHat.experiment";
import { hatQuestionsLook } from "../agent-session/acpmux/question/hatQuestions.experiment";
import { hatChevronLook, hatDoneCheckPlace, hatDoneLook } from "../agent-session/acpmux/subagents/hatParts.experiment";
import { goalHatPlace } from "../agent-session/acpmux/goalHat.experiment";
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
import { cmuxLinkLook } from "../agent-session/acpmux/chips/cmuxLinkLook.experiment";
import { sentPasteJoin } from "../agent-session/acpmux/conversation/sentPasteJoin.experiment";
import { sentMessageLook } from "../agent-session/acpmux/conversation/sentMessageLook.experiment";
import { contextRingLook } from "../agent-session/acpmux/contextRingLook.experiment";
import { contextRingMotion } from "../agent-session/acpmux/contextRingMotion.experiment";
import { planUsageLook } from "../agent-session/acpmux/planUsageLook.experiment";
import { emojiShortcodeLook } from "../agent-session/acpmux/emojiShortcodeLook.experiment";
import { sendStopMorph } from "../agent-session/acpmux/composer/sendStopMorph.experiment";
import { sendMenuLook } from "../agent-session/acpmux/composer/sendMenuLook.experiment";
import { fileKindIcon } from "../agent-session/acpmux/chips/fileKindIcon.experiment";
import { followMotion } from "../agent-session/acpmux/conversation/followMotion.experiment";
import { timeHoverWording } from "../agent-session/acpmux/conversation/timeHoverWording.experiment";
import { timeHoverDate } from "../agent-session/acpmux/conversation/timeHoverDate.experiment";
import { fieldGrowthMotion } from "../agent-session/acpmux/composer/fieldGrowth.experiment";
import { composerDockMotion } from "../agent-session/acpmux/composer/dockMotion.experiment";
import { teamAudit } from "../agent-session/acpmux/teamAudit/teamAudit.experiment";
import { jumpPairLook } from "../agent-session/acpmux/jumpPair.experiment";
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [
  diffTreeDisclosure,
  treeNameFade,
  sessionReplay,
  steerQueueExperiment,
  chiefDock,
  hoverActions,
  startedSessionCards,
  fileKindIcon,
  followMotion,
  finishedTaskLook,
  claudeTurnFold,
  commandLabelLook,
  liveTurnWork,
  turnFoldReplies,
  turnFoldSteered,
  workedForMessages,
  threadMinimapLayout,
  threadMinimapHeight,
  threadMinimapGutter,
  threadMinimapRestTick,
  newTabHeadline,
  newTabComposerTrailingGap,
  newTabIconColumn,
  threadMinimapLit,
  threadMinimapMark,
  threadMinimapWave,
  threadMinimapIncoming,
  threadMinimapCard,
  chatMinimapPlaceholder,
  codeActionsLook,
  turnErrorCard,
  pausedMachineResume,
  codeRouterOffer,
  stoppedTurnLook,
  timeHoverWording,
  timeHoverDate,
  chromiumGlassUnderlay,
  questionPreviewLayout,
  toolErrorLook,
  tableActionsPlace,
  expandRowLook,
  selectionReplyWrap,
  backgroundReactionLook,
  backgroundTurnLook,
  cloudStartLook,
  cloudProgressLook,
  cloudStartAskLook,
  agentStartLook,
  liveLineTokens,
  compactingLine,
  liveLineTimes,
  liveTurnClock,
  runScroll,
  oneRowPerCall,
  backgroundHintRoom,
  trayPanelLook,
  trayRowLook,
  trayStopLook,
  trayMotionLook,
  composerHatLook,
  hatQuestionsLook,
  hatChevronLook,
  goalHatPlace,
  hatDoneLook,
  hatDoneCheckPlace,
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
  cloudStartComposerLook,
  cmuxLinkLook,
  sentPasteJoin,
  sentMessageLook,
  contextRingLook,
  contextRingMotion,
  planUsageLook,
  emojiShortcodeLook,
  pastePlaceholderLook,
  sendStopMorph,
  sendMenuLook,
  fieldGrowthMotion,
  composerDockMotion,
  teamAudit,
  jumpPairLook,
];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
