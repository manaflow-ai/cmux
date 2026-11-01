/// The app actions the header runs on its tab (CmuxNextAgentPane AgentPaneModel.headerActions).
export const HEADER_ACTIONS = {
  terminal: "splitRight",
  splitDown: "splitDown",
  browser: "splitBrowserRight",
  changes: "openDiffViewer",
  /// Not an app action: the App opens the Files tree (CmuxNextApp AgentChatSplitToggles.files).
  files: "files",
  /// Not an app action: its own `pane.action` (CmuxNextAgentPane AgentPaneModel.previewAction).
  preview: "preview",
  rename: "renameTab",
  pin: "palette.toggleTabPin",
  moveRight: "moveSurfaceToPaneRight",
  newWorkspace: "palette.moveTabToNewWorkspace",
  newWindow: "tab.moveToNewWindow",
  /// Not an app action: Start Agent's panel holds the chat (CmuxNextAgentPane AgentPaneHeaderHooks.moveToFloatingChat).
  floatingChat: "floatingChat",
  close: "closeTab",
} as const;
