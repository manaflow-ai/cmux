import { useT } from "./i18n";
import { watchedApp } from "./watchBannerModel";
/// A chat that shows a Claude Code or Codex session another app runs, without running it
/// (acpmux `hub/watch.rs`): the transcript follows that app live; a reply, or Take Over, makes this
/// chat run the conversation (acpmux refuses while the other app still runs
/// it, and the pane then offers Open Anyway or Fork It). Viewing never blocks starting a session:
/// Continue in New Chat forks a Claude Code session into a new chat, and New Chat Here starts a
/// Codex chat in its folder (a Codex session cannot be forked while another app runs it). It drops in
/// from the top of the chat (ui/popupSurface.css `data-enter`).
/// `bridged`: a Claude desktop session acpmux delivers replies into (`bridgedWatch`), so the hint
/// says where a reply goes instead of that it takes the session over.
export function WatchBanner({
  family,
  bridged = false,
  onTakeOver,
  onContinue,
}: {
  family: string;
  bridged?: boolean;
  onTakeOver(): void;
  onContinue?(): void;
}) {
  const t = useT();
  return (
    <div className="acpmux-link-missing acpmux-watch-banner" data-enter="top">
      <p>{t("watch.banner", { app: watchedApp(family) })}</p>
      <p className="acpmux-watch-hint">{t(bridged ? "watch.composerBridged" : "watch.composer")}</p>
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
