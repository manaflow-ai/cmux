import { useT } from "./i18n";

/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}

/// A chat that shows a Claude Code or Codex session another app runs, without running it
/// (acpmux `hub/watch.rs`): the transcript follows that app live, the composer sends nothing, and
/// Take Over makes this chat run the conversation (acpmux refuses while the other app still runs
/// it, and the pane then offers Open Anyway or Fork It).
export function WatchBanner({ family, onTakeOver }: { family: string; onTakeOver(): void }) {
  const t = useT();
  return (
    <div className="acpmux-link-missing acpmux-watch-banner">
      <p>{t("watch.banner", { app: watchedApp(family) })}</p>
      <p className="acpmux-live-chat-actions">
        <button type="button" className="acpmux-folder-choice-button" onClick={onTakeOver}>
          {t("watch.takeOver")}
        </button>
      </p>
    </div>
  );
}
