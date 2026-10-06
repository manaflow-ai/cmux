import { useT } from "./i18n";

/// A new chat in a workspace without a folder starts in the workspace's private agent-home folder
/// (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE). This line above the composer says so and offers
/// "Choose Folder…": the host's native folder sheet (`workspace.chooseFolder`), which the host
/// opens only after this real click.
export function FolderChoice({ onChoose }: { onChoose(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice">
      {t("agentHome.notice")}{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onChoose}>
        {t("agentHome.choose")}
      </button>
    </output>
  );
}
