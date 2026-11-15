// A chat that could not start on another machine names its one-click way out, never a dead end
// (Leo, 2026-10-31: "let's work on improving this a LOT"). Keyed on the refusal's code, never its
// words (cmux-tui agent_session_attach.rs Refusal::code; the app's own `app.folder_needed`).

/// A start whose agent answered that it is not signed in on the machine (cmux-tui
/// agent_session_start.rs `StartRefused::of_session_new`; acpmux on this Mac types the same answer
/// with `data.reason` ``SIGN_IN_REASON``, which harnessSwitch.ts reads as this code). hq#11225.
export const SIGN_IN_REQUIRED = "agent_session.sign_in_required";
/// acpmux's `data.reason` for that answer (recovery.rs `SIGN_IN_REQUIRED`).
export const SIGN_IN_REASON = "agent.sign_in_required";

/// What the failed start card offers next to Retry.
export type StartRefusalAction = "newCloudMachine" | "chooseFolder" | "signIn";

/// The way out of a refused start, or none (Retry only).
export function startRefusalAction(code: string | undefined): StartRefusalAction | undefined {
  switch (code) {
    // A teammate's machine: the person's own machine takes the chat.
    case "agent_session.team_vm_blocked":
      return "newCloudMachine";
    // No folder there, the machine lists no work folder (an older cmux-tui): pick one.
    case "app.folder_needed":
      return "chooseFolder";
    // The agent is not signed in there: its own sign-in, then Retry.
    case SIGN_IN_REQUIRED:
      return "signIn";
    default:
      return undefined;
  }
}

/// Where a card's action goes. Choose Folder on a chat on another machine opens that machine's
/// folder menu (the composer's Location menu, listed from its `project.list`), never this Mac's open
/// panel, which the host refuses there (cmux#29213).
export type StartRefusalRoute = "newCloudMachine" | "machineFolderMenu" | "folderPanel";

export function startRefusalRoute(
  action: Exclude<StartRefusalAction, "signIn">,
  remoteChat: boolean,
): StartRefusalRoute {
  if (action === "newCloudMachine") return "newCloudMachine";
  return remoteChat ? "machineFolderMenu" : "folderPanel";
}

/// How Sign in signs the refused agent in: a chat on another machine with the machine's own sign-in
/// card (CloudSignIn.tsx over cloudAgentLogin.ts, the agent's login run there), a chat on this Mac
/// with the agent's login command in a terminal tab (as HarnessHealthNotice does). A chat elsewhere
/// whose machine has no sign-in for it never runs a login on this Mac: undefined, and the card says
/// where to sign in instead.
export type SignInRoute = "card" | "terminal";

export function signInRoute(chat: { elsewhere: boolean; card: boolean; login: boolean }): SignInRoute | undefined {
  if (chat.elsewhere) return chat.card ? "card" : undefined;
  return chat.login ? "terminal" : undefined;
}
