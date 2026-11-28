import { useT } from "./i18n";

/// The outside chat this pane resumes is still open in another process (a terminal running
/// `claude --resume <id>`, a TUI that wrote it minutes ago); acpmux refused it (`adopt.live`).
/// Resuming it here too would put two harnesses on one conversation. The line says so, names the
/// process when acpmux found one, and offers Fork It (Claude Code: a new chat from this one) and
/// Open Anyway.
export function LiveChatChoice({
  canFork,
  command,
  onChoose,
}: {
  canFork: boolean;
  command?: string;
  onChoose(choice: "fork" | "open"): void;
}) {
  const t = useT();
  return (
    <div className="acpmux-link-missing acpmux-live-chat" role="alert">
      <p>{t("adopt.live.notice")}</p>
      {command && <code className="acpmux-live-chat-command">{command}</code>}
      <p className="acpmux-live-chat-actions">
        {canFork && (
          <button type="button" className="acpmux-folder-choice-button" onClick={() => onChoose("fork")}>
            {t("adopt.live.fork")}
          </button>
        )}
        <button type="button" className="acpmux-folder-choice-button" onClick={() => onChoose("open")}>
          {t("adopt.live.open")}
        </button>
      </p>
    </div>
  );
}
