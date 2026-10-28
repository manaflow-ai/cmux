// Every experiment in the webviews, by id. A lane adds its `<name>.experiment.ts` here (one import
// and one list item).
// Removing an experiment (its winner shipped as the plain code path) removes its line.
import { diffTreeDisclosure, treeNameFade } from "../agent-session/acpmux/changes/treeMotion.experiment";
import { sessionReplay } from "../agent-session/acpmux/replay/replay.experiment";
import { chiefDock } from "../agent-session/acpmux/chiefDock.experiment";
import { newTabHeadline } from "../agent-session/acpmux/newtab/headline.experiment";
import { hoverActions } from "../ui/hoverActions.experiment";
import { toolErrorLook } from "../agent-session/acpmux/conversation/toolError.experiment";
import { threadMinimapLayout } from "../agent-session/acpmux/threadMinimap/layout.experiment";
import { threadMinimapLit } from "../agent-session/acpmux/threadMinimap/lit.experiment";
import { threadMinimapMark } from "../agent-session/acpmux/threadMinimap/mark.experiment";
import { chatMinimapPlaceholder } from "../agent-session/acpmux/chatMinimap/placeholder.experiment";
import { startedSessionCards } from "../agent-session/acpmux/started/startedSessions.experiment";
import { turnErrorCard } from "../agent-session/acpmux/conversation/turnErrorCard.experiment";
import { codeRouterOffer } from "../agent-session/acpmux/conversation/codeRouterOffer.experiment";
import { chromiumGlassUnderlay } from "../ui/glass/chromiumUnderlay.experiment";
import { questionPreviewLayout } from "../agent-session/acpmux/question/previewLayout.experiment";
import { trayPanelLook } from "../agent-session/acpmux/subagents/trayPanel.experiment";
import type { Experiment } from "./experiment";

export const EXPERIMENTS: readonly Experiment[] = [
  diffTreeDisclosure,
  treeNameFade,
  sessionReplay,
  chiefDock,
  hoverActions,
  startedSessionCards,
  threadMinimapLayout,
  newTabHeadline,
  threadMinimapLit,
  threadMinimapMark,
  chatMinimapPlaceholder,
  turnErrorCard,
  codeRouterOffer,
  chromiumGlassUnderlay,
  questionPreviewLayout,
  toolErrorLook,
  trayPanelLook,
];

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}
