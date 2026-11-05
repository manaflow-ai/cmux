import { applyAgentTheme } from "../shared/theme";
import { configureSubagentTray } from "./subagents/runningTray";
import { configureSubagentTrayPlacement } from "./subagents/subagentTrayPlacement";
import { configureSelectionReply } from "./conversation/selectionReplyModel";
import { configureChatWidth } from "./chatWidth";
import { configureCodexToolRuns } from "./codexToolRuns";
import { configureLiveLineBelow } from "./liveLineBelow";
import { configureToolRunLook } from "./toolRunLook";
import { configureSentLook } from "./conversation/sentMessageLineModel";
import { configureInboxNoticeLook } from "./conversation/inboxNoticeLook";
import { configureMessageLineLook } from "./conversation/messageLineLook";
import { configureNoticeLook } from "./conversation/noticeLook";
import { configureTurnActionsPlacement } from "./turnActionsPlacement";

/** The same host theme before mount and on subsequent bridge pushes. */
export function applyPaneTheme(theme: Record<string, unknown>): void {
  applyAgentTheme(theme as never);
  configureChatWidth(theme.chatWidth);
  configureCodexToolRuns(theme.codexToolRuns);
  configureLiveLineBelow(theme.liveLineBelow);
  configureToolRunLook(theme.toolRunLook);
  configureSentLook(theme.sentLook);
  configureInboxNoticeLook(theme.inboxNoticeLook);
  configureMessageLineLook(theme.messageLineLook);
  configureNoticeLook(theme.noticeLook);
  configureTurnActionsPlacement(theme.turnActionsPlacement);
  configureSubagentTray(theme.subagentTray);
  configureSubagentTrayPlacement(theme.subagentTrayPlacement);
  configureSelectionReply(theme.selectionReply);
}

/** Install the user font/layout stylesheet before the first render when already known. */
export function applyPaneThemeCSS(themeCSS: string): void {
  let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null;
  if (!style) {
    style = document.createElement("style");
    style.id = "acpmux-user-theme";
    document.head.append(style);
  }
  style.textContent = themeCSS;
}
