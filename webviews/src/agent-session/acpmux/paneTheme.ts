import { SCROLLER_FADE_ATTRIBUTE } from "../../scrollers";
import { guardedStylesheet } from "../../surfaces/stylesheetGuard";
import { applyAgentTheme } from "../shared/theme";
import { configureSubagentTrayPlacement } from "./subagents/subagentTrayPlacement";
import { configureSelectionReply } from "./conversation/selectionReplyModel";
import { configureToolRunLook } from "./toolRunLook";
import { configureSentLook } from "./conversation/sentMessageLineModel";
import { configureInboxNoticeLook } from "./conversation/inboxNoticeLook";
import { configureInboxThreadLook } from "./conversation/inboxThreadLook";
import { configureReceivedLook } from "./conversation/receivedLook";
import { configureMessageLineLook } from "./conversation/messageLineLook";
import { configureNoticeBodyLook, configureNoticeLook } from "./conversation/noticeLook";
import { configureTurnActionsPlacement } from "./turnActionsPlacement";

/** The same host theme before mount and on subsequent bridge pushes. */
export function applyPaneTheme(theme: Record<string, unknown>): void {
  applyAgentTheme(theme as never);
  // The agent chat's scrollbars fade at rest and widen near the pointer (scrollers.ts).
  document.documentElement.setAttribute(SCROLLER_FADE_ATTRIBUTE, "");
  configureToolRunLook(theme.toolRunLook);
  configureSentLook(theme.sentLook);
  configureInboxNoticeLook(theme.inboxNoticeLook);
  configureInboxThreadLook(theme.inboxThreadLook);
  configureReceivedLook(theme.receivedLook);
  configureMessageLineLook(theme.messageLineLook);
  configureNoticeLook(theme.noticeLook);
  configureNoticeBodyLook(theme.noticeBodyLook);
  configureTurnActionsPlacement(theme.turnActionsPlacement);
  configureSubagentTrayPlacement(theme.subagentTrayPlacement);
  configureSelectionReply(theme.selectionReply);
}

const USER_THEME_ID = "acpmux-user-theme";
let userThemeKeptLast: MutationObserver | undefined;

/**
 * Install the person's `agent-pane/theme.css` before the first render when already known: any CSS,
 * after the pane's own styles. It stays the head's last element, so a person's `:root { --token: ...
 * }` (cmux.agentPane.style/1, schemas/agent-pane/style-tokens.json) wins over the pane's own `:root`
 * at equal specificity even when a stylesheet loads after it (a lazily loaded chunk's CSS): before,
 * such a sheet silently took the token back. A sheet that would load something by address
 * (cmux.stylesheetGuard/1: an `@import`, a `url()` other than `data:`) is refused whole and the last
 * good one stays; the style element's `data-refused` says why.
 */
export function applyPaneThemeCSS(themeCSS: string): void {
  let style = document.getElementById(USER_THEME_ID) as HTMLStyleElement | null;
  if (!style) {
    style = document.createElement("style");
    style.id = USER_THEME_ID;
  }
  const sheet = style;
  delete sheet.dataset.refused;
  sheet.textContent = guardedStylesheet(themeCSS, sheet.textContent ?? "", (why) => {
    sheet.dataset.refused = why;
    console.warn(`agent-pane/theme.css not applied: ${why}; it loads nothing by address (inline images as data: URLs)`);
  });
  if (document.head.lastElementChild !== style) document.head.append(style);
  if (!userThemeKeptLast && typeof MutationObserver !== "undefined") {
    // Fires only when the head's children change (a stylesheet added): moving the sheet back is one
    // more mutation, after which it is last and nothing moves.
    userThemeKeptLast = new MutationObserver(() => {
      const sheet = document.getElementById(USER_THEME_ID);
      if (sheet && sheet.parentNode === document.head && document.head.lastElementChild !== sheet)
        document.head.append(sheet);
    });
    userThemeKeptLast.observe(document.head, { childList: true });
  }
}
