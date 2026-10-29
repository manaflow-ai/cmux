import { useT } from "./i18n";

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

/// A new chat in a workspace without a folder starts in the workspace's private agent-home folder
/// (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE). The folder chip's menu says so, and its Choose folder… is
/// the host's native folder sheet (`workspace.chooseFolder`), which the host opens only after a real
/// click. This line above the composer says it again only with `error`, the host's localized refusal
/// (an older background service, a folder it could not save), and offers the sheet again.
export function FolderChoice({ onChoose, error }: { onChoose(): void; error?: string }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice">
      {t("agentHome.notice")}{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onChoose}>
        {t("agentHome.choose")}
      </button>
      {error && (
        <>
          {" "}
          <span role="alert">{error}</span>
        </>
      )}
    </output>
  );
}
