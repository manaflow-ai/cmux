import { useState } from "react";
import { LINK_DOWN_SAID_MS, RESUME_NOTE_DELAY_MS, useAfterDelay } from "../afterDelay";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { autoLine, type AutoLine, type AutoSession } from "./autoSession";
import type { LeftoverAction, LeftoverShown } from "./leftover";

/// How many of the kept files Show lists before "+N more": the notice sits above the transcript and
/// must not push it off the pane.
export const LEFTOVER_FILES_SHOWN = 8;

export type AutoSessionBannerProps = {
  auto: AutoSession;
  /// A prompt waits or a turn runs: what makes a chat nobody runs say Resuming (autoSession.ts).
  sending: boolean;
  /// The existing Cloud start flow (App.tsx `connectMachine("cloud")`), for a chat with no machine.
  onSetUpCloud(): void;
  /// `_acpmux/auto_session/leftover` for this chat (direct.ts `autoLeftover`).
  onLeftover(action: LeftoverAction): Promise<LeftoverShown | undefined>;
  /// A leftover action that did not run: said as the pane says any failed click (paneToasts.ts).
  onFailed(text: string): void;
  /// The gallery's settled variants pass 0; the pane leaves the defaults.
  noteDelayMs?: number;
};

/// What an Auto chat says under its header (plans/cmux-next/auto-mode/UI-NOTES.md): where it runs
/// when that is not this Mac, the one thing stopping Auto with its action, and the notice of changes
/// this Mac made after the chat moved. It is drawn with the peer copy banner's and the watch banner's
/// parts (PeerCopyBanner.tsx, WatchBanner.tsx), which already say a Cloud chat's machine is paused,
/// starting or offline in this place; a chat this Mac runs draws nothing.
export function AutoSessionBanner({
  auto,
  sending,
  onSetUpCloud,
  onLeftover,
  onFailed,
  noteDelayMs,
}: AutoSessionBannerProps) {
  const line = autoLine(auto, sending);
  return (
    <>
      {line && (
        <AutoStateLine
          key={line.kind === "blocked" ? line.blocked : line.kind}
          line={line}
          onSetUpCloud={onSetUpCloud}
          noteDelayMs={noteDelayMs}
        />
      )}
      {auto.leftover && <AutoLeftoverNotice files={auto.leftover.files} onLeftover={onLeftover} onFailed={onFailed} />}
    </>
  );
}

/// How long a line stays out of sight: a resume reads as part of thinking for RESUME_NOTE_DELAY_MS
/// and a dropped network heals on its own within LINK_DOWN_SAID_MS (afterDelay.ts), so neither is
/// said before then. Everything else is a settled state and shows at once.
function lineDelay(line: AutoLine): number {
  if (line.kind === "resuming") return RESUME_NOTE_DELAY_MS;
  if (line.kind === "blocked" && line.blocked === "offline") return LINK_DOWN_SAID_MS;
  return 0;
}

function AutoStateLine({
  line,
  onSetUpCloud,
  noteDelayMs,
}: {
  line: AutoLine;
  onSetUpCloud(): void;
  noteDelayMs?: number;
}) {
  const t = useT();
  const shown = useAfterDelay(true, noteDelayMs ?? lineDelay(line));
  const state = line.kind === "blocked" ? line.blocked : line.kind;
  return (
    <div className="acpmux-peer-copy-slot" data-shown={shown || undefined}>
      <div className="acpmux-link-missing acpmux-peer-copy" data-enter="top" data-auto={state}>
        {line.kind === "resuming" ? (
          <output className="acpmux-peer-copy-title">
            <Spinner size={12} loading className="acpmux-peer-copy-spinner" />
            {t("composer.envResuming")}
          </output>
        ) : line.kind === "blocked" ? (
          <p className="acpmux-peer-copy-title">
            <span>
              {t(
                line.blocked === "no_machine"
                  ? "auto.blocked.noMachine"
                  : line.blocked === "too_large"
                    ? "auto.blocked.tooLarge"
                    : "auto.blocked.offline",
              )}
            </span>
            {line.blocked === "no_machine" && (
              <button type="button" className="acpmux-folder-choice-button" onClick={onSetUpCloud}>
                {t("composer.newCloudMachine")}
              </button>
            )}
          </p>
        ) : (
          <>
            <p className="acpmux-peer-copy-title">{t("auto.state.cloud")}</p>
            {line.kind === "comingBack" && <p className="acpmux-watch-hint">{t("auto.state.comingBack")}</p>}
          </>
        )}
      </div>
    </div>
  );
}

type LeftoverStep =
  | { step: "rest" }
  | { step: "loading" }
  | { step: "shown"; shown: LeftoverShown }
  | { step: "confirm"; shown?: LeftoverShown }
  | { step: "running"; shown?: LeftoverShown };

/// The changes this Mac made after the chat moved to the Cloud, kept aside: Show lists the files,
/// Apply puts them in the folder, Discard drops them after one more click (the worktree pill's
/// Remove asks the same way, header/WorktreeRemove.tsx). The notice goes when the chat's row stops
/// carrying a leftover.
function AutoLeftoverNotice({
  files,
  onLeftover,
  onFailed,
}: {
  files: number;
  onLeftover: AutoSessionBannerProps["onLeftover"];
  onFailed: AutoSessionBannerProps["onFailed"];
}) {
  const t = useT();
  const [state, setState] = useState<LeftoverStep>({ step: "rest" });
  const shown = "shown" in state ? state.shown : undefined;
  const busy = state.step === "loading" || state.step === "running";
  const show = () => {
    if (shown) return setState({ step: "rest" });
    setState({ step: "loading" });
    const failed = () => {
      setState({ step: "rest" });
      onFailed(t("auto.leftover.showFailed"));
    };
    // An answer that names no file has nothing to list: said as a Show that did not work.
    onLeftover("show").then(
      (answer) => (answer?.files.length ? setState({ step: "shown", shown: answer }) : failed()),
      failed,
    );
  };
  const run = (action: "apply" | "discard") => {
    setState({ step: "running", ...(shown ? { shown } : {}) });
    onLeftover(action).then(
      // The row drops its leftover and the notice goes with it; until then it stays as it was.
      () => setState(shown ? { step: "shown", shown } : { step: "rest" }),
      () => {
        setState(shown ? { step: "shown", shown } : { step: "rest" });
        onFailed(t(action === "apply" ? "auto.leftover.applyFailed" : "auto.leftover.discardFailed"));
      },
    );
  };
  const listed = shown?.files.slice(0, LEFTOVER_FILES_SHOWN) ?? [];
  const more = (shown?.files.length ?? 0) - listed.length;
  return (
    <div className="acpmux-link-missing acpmux-watch-banner" data-enter="top" data-auto="leftover" data-files={files}>
      <p>{t("auto.leftover.notice")}</p>
      {shown && (
        <p className="acpmux-watch-hint" data-auto-files>
          {listed.map((file) => (
            <code key={file} className="acpmux-live-chat-command" title={file}>
              {file}
            </code>
          ))}
          {more > 0 && <span>{t("planBuild.moreFiles", { n: more })}</span>}
        </p>
      )}
      {state.step === "confirm" ? (
        <p className="acpmux-live-chat-actions" role="group" aria-label={t("auto.leftover.discardAsk")}>
          <span>{t("auto.leftover.discardAsk")}</span>
          <button type="button" className="acpmux-folder-choice-button" onClick={() => run("discard")}>
            {t("auto.leftover.discard")}
          </button>
          <button
            type="button"
            className="acpmux-folder-choice-button"
            onClick={() => setState(shown ? { step: "shown", shown } : { step: "rest" })}
          >
            {t("header.worktreeRemoveKeep")}
          </button>
        </p>
      ) : (
        <p className="acpmux-live-chat-actions">
          <button
            type="button"
            className="acpmux-folder-choice-button"
            disabled={busy}
            aria-expanded={shown !== undefined}
            onClick={show}
          >
            {t(shown ? "rules.hide" : "auto.leftover.show")}
          </button>
          <button type="button" className="acpmux-folder-choice-button" disabled={busy} onClick={() => run("apply")}>
            {t("auto.leftover.apply")}
          </button>
          <button
            type="button"
            className="acpmux-folder-choice-button"
            disabled={busy}
            onClick={() => setState({ step: "confirm", ...(shown ? { shown } : {}) })}
          >
            {t("auto.leftover.discard")}
          </button>
        </p>
      )}
    </div>
  );
}
