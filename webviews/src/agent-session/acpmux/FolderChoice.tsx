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
}): boolean {
  return state.offered && state.freshChat && !state.quick && !state.projectDraft;
}

/// A new chat in a workspace without a folder starts in the workspace's private agent-home folder
/// (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE). This line above the composer says so and offers
/// "Choose Folder…": the host's native folder sheet (`workspace.chooseFolder`), which the host
/// opens only after this real click. `error` is the host's localized refusal (an older background
/// service, a folder it could not save), shown after the button.
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
