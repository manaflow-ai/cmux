// Centralized UI strings for the /agent-chat surface (the `src/labels.ts` /
// `comments/labels.ts` precedent). The webview surfaces are deliberately
// English-only, matching the agent-session surface: the content they render
// (agent transcripts, tool output, markdown) is itself untranslated agent
// output, so chrome strings stay English and live in one module instead of
// scattered through JSX. Swift-side strings (alerts, menus, daemon errors)
// are localized through Resources/Localizable.xcstrings as usual.

export const agentChatLabels = {
  // Header strip.
  providerFallback: "Agent",
  sessionFallbackTitle: "Agent session",
  statusLive: "Live",
  statusDaemonUnavailable: "Daemon unavailable",

  // Daemon banner (items already on screen).
  daemonBannerTitle: "Agent daemon unavailable",
  daemonBannerSuffix: "Showing the last known transcript.",

  // Empty states.
  connectingTitle: "Connecting",
  connectingDetail: "Reaching the agent daemon…",
  daemonUnavailableTitle: "Agent daemon unavailable",
  daemonUnavailableDetail: "The conversation daemon could not be reached.",
  subscribeFailedTitle: "Chat unavailable",
  subscribeFailedDetail: "The conversation stream could not be opened.",
  noSessionTitle: "No session",
  noSessionDetail: "No agent session was resolved for this pane.",
  loadingTitle: "Loading transcript",
  loadingDetail: "Waiting for the first snapshot…",
  noConversationTitle: "No conversation yet",
  noConversationDetail: "This session's transcript has no items so far.",

  // Timeline rows.
  agentWorking: "Agent is working",
  streamError: "Stream error",
  streamErrorRetrying: " (retrying)",
  jumpToLatest: "↓ Jump to latest",
  reasoning: "Reasoning",
  plan: "Plan",
  contextCompacted: "Context compacted",
  errorRow: "Error",
  stoppedRow: "Stopped",
  eventRow: "Event",
  statusInProgress: "In progress",
  statusFailed: "Failed",
  statusDeclined: "Declined",
  statusCompleted: "Completed",
  noToolPayload: "No input or output recorded.",
  imageAttachmentSingular: "1 image attachment",

  // Rich tool rows (toolRows.tsx).
  showLess: "Show less",
  newFileBadge: "new",
  deletedFileBadge: "deleted",
  exitPrefix: "exit ",
  noCommandOutput: "No output.",
  noFilePreview: "No preview recorded.",
  searchQueryFallback: "Web search",
  diffFallbackTitle: "File change",

  // Pending-request banner.
  waitingForInput: "Agent is waiting for your input",
  waitingForPermission: "Agent is waiting for permission",
  waiting: "Agent is waiting",

  // Tool badges (display.ts).
  toolRun: "Run",
  toolEdit: "Edit",
  toolMCP: "MCP",
  toolGeneric: "Tool",
  toolSearch: "Search",
  providerClaude: "Claude",
  providerCodex: "Codex",

  // Bridge errors.
  bridgeRequestFailed: "Native bridge request failed.",
  bridgeUnavailable: "Native bridge is unavailable.",
} as const;

export function imageAttachmentLabel(count: number): string {
  return count === 1 ? agentChatLabels.imageAttachmentSingular : `${count} image attachments`;
}

export function showMoreLinesLabel(count: number): string {
  return count === 1 ? "Show 1 more line" : `Show ${count} more lines`;
}

export function unchangedLinesLabel(count: number): string {
  return count === 1 ? "1 unchanged line" : `${count} unchanged lines`;
}

export function exitCodeLabel(code: number): string {
  return `${agentChatLabels.exitPrefix}${code}`;
}

/** Note for diff lines dropped by the parse-time cap (not expandable). */
export function moreLinesNotShownLabel(count: number): string {
  return count === 1 ? "1 more line not shown" : `${count} more lines not shown`;
}
