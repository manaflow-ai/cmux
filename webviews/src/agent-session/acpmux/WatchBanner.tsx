import { useT } from "./i18n";

/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  // l10n-allow: product names (Codex, Claude Code), never translated.
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}

/// A chat that shows a Claude Code or Codex session another app runs, without running it
/// (acpmux `hub/watch.rs`): the transcript follows that app live; a reply, or Take Over, makes this
/// chat run the conversation (acpmux refuses while the other app still runs
/// it, and the pane then offers Open Anyway or Fork It). Viewing never blocks starting a session:
/// Continue in New Chat forks a Claude Code session into a new chat, and New Chat Here starts a
/// Codex chat in its folder (a Codex session cannot be forked while another app runs it). It drops in
/// from the top of the chat (ui/popupSurface.css `data-enter`).
export function WatchBanner({
  family,
  onTakeOver,
  onContinue,
}: {
  family: string;
  onTakeOver(): void;
  onContinue?(): void;
}) {
  const t = useT();
  return (
    <div className="acpmux-link-missing acpmux-watch-banner" data-enter="top">
      <p>{t("watch.banner", { app: watchedApp(family) })}</p>
      <p className="acpmux-watch-hint">{t("watch.composer")}</p>
      <p className="acpmux-live-chat-actions">
        <button type="button" className="acpmux-folder-choice-button" onClick={onTakeOver}>
          {t("watch.takeOver")}
        </button>
        {onContinue && (
          <button type="button" className="acpmux-folder-choice-button" onClick={onContinue}>
            {t(family === "claude" ? "watch.continue" : "watch.newChat")}
          </button>
        )}
      </p>
    </div>
  );
}
