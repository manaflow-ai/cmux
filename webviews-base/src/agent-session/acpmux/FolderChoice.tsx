import { useT } from "./i18n";
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
