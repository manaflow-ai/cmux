import { translate, useT } from "./i18n";

/// The app a watched chat's conversation runs in, by acpmux harness family. Product names, never
/// translated.
export function watchedApp(family: string): string {
  return family === "codex" ? "Codex" : family === "claude" ? "Claude Code" : family;
}

/// A word for a POSIX shell: as is when it is plain, else in single quotes.
function shellWord(word: string): string {
  return /^[\w@%+=:,./-]+$/.test(word) ? word : `'${word.replace(/'/g, "'\\''")}'`;
}

/// The transcript line a take-over leaves (acpmux `watch_taken_over`): how the conversation goes
/// on in the app it came from (Leo 2026-10-19, "going back"). A fork leaves the original as it
/// was; a take-over means two apps on one conversation unless this chat is closed first.
export function watchGoBack(record: {
  family?: unknown;
  agentSessionId?: unknown;
  cwd?: unknown;
  fork?: unknown;
}): string | undefined {
  const { family, agentSessionId: id, cwd } = record;
  if (typeof id !== "string" || !id || (family !== "claude" && family !== "codex")) return undefined;
  const resume = family === "claude" ? `claude --resume ${shellWord(id)}` : `codex resume ${shellWord(id)}`;
  const command = typeof cwd === "string" && cwd ? `cd ${shellWord(cwd)} && ${resume}` : resume;
  return translate(record.fork === true ? "watch.goBackFork" : "watch.goBack", { app: watchedApp(family), command });
}

/// A chat that shows a Claude Code or Codex session another app runs, without running it
/// (acpmux `hub/watch.rs`): the transcript follows that app live; a reply, or Take Over, makes this
/// chat run the conversation (acpmux refuses while the other app still runs
/// it, and the pane then offers Open Anyway or Fork It). Viewing never blocks starting a session:
/// Continue in New Chat forks a Claude Code session into a new chat, and New Chat Here starts a
/// Codex chat in its folder (a Codex session cannot be forked while another app runs it).
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
    <div className="acpmux-link-missing acpmux-watch-banner">
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
