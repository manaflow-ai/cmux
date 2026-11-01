// A chat that could not start on another machine names its one-click way out, never a dead end
// (Leo, 2026-10-31: "let's work on improving this a LOT"). Keyed on the refusal's code, never its
// words (cmux-tui agent_session_attach.rs Refusal::code; the app's own `app.folder_needed`).

/// What the failed start card offers next to Retry.
export type StartRefusalAction = "newCloudMachine" | "chooseFolder";

/// The way out of a refused start, or none (Retry only).
export function startRefusalAction(code: string | undefined): StartRefusalAction | undefined {
  switch (code) {
    // A teammate's machine: the person's own machine takes the chat.
    case "agent_session.team_vm_blocked":
      return "newCloudMachine";
    // No folder there, the machine lists no work folder (an older cmux-tui): pick one.
    case "app.folder_needed":
      return "chooseFolder";
    default:
      return undefined;
  }
}

/// Where a card's action goes. Choose Folder on a chat on another machine opens that machine's
/// folder menu (the composer's Location menu, listed from its `project.list`), never this Mac's open
/// panel, which the host refuses there (cmux#29213).
export type StartRefusalRoute = "newCloudMachine" | "machineFolderMenu" | "folderPanel";

export function startRefusalRoute(action: StartRefusalAction, remoteChat: boolean): StartRefusalRoute {
  if (action === "newCloudMachine") return "newCloudMachine";
  return remoteChat ? "machineFolderMenu" : "folderPanel";
}
