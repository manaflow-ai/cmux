/// Whether the line shows: the host offered it (`chooseFolder`: a new chat that runs in the
/// workspace's agent-home), the chat is still new (no turn yet), not in the Quick Composer, and the
/// user picked no project for this draft. The chat's session is no condition: a new chat starts
/// its session at once (the prewarmed process), still in agent-home.
export function showsFolderChoice(state: {
  offered: boolean;
  freshChat: boolean;
  quick: boolean;
  projectDraft?: string;
  sessionId?: string;
  /// The chat opened without its folder and shows its own missing-folder line (with Choose Folder).
  missingFolder?: boolean;
}): boolean {
  return state.offered && state.freshChat && !state.quick && !state.projectDraft && !state.missingFolder;
}
