import { useState } from "react";
import { RESUME_NOTE_DELAY_MS, useAfterDelay } from "./afterDelay";
import { experimentArm } from "../../experiments/experiment";
import { Spinner } from "./conversation/icons";
import { relativeTime } from "./conversation/relativeTime";
import { currentLanguage, useT } from "./i18n";
import { errorMessage } from "./transportErrors";
import type { PeerCopyState } from "./peerCopy";
import type { PeerMachineState } from "./peerCloudMachine";
import { pausedMachineResume } from "./pausedMachine.experiment";

/// A peer chat drawn from the Mac's copy while its machine does not answer (peerCopy.ts): the
/// transcript is what the Mac last saw and may be out of date, until the machine is back and the
/// chat catches up. Drops in from the top of the chat (ui/popupSurface.css `data-enter`), as the
/// watch banner does. When the machine is one of the account's Cloud machines
/// (peerCloudMachine.ts), a paused one says it is paused and offers Resume, and one starting says
/// so with a spinner, instead of "offline" (cmuxterm-hq#4755).
///
/// A Cloud machine pauses on its own, between tool calls too, so for any peer that may be one (the App
/// passes `noteDelayMs` 0 for an ssh peer) the banner stays out of sight at first: it shows only once
/// the machine has been away for RESUME_NOTE_DELAY_MS (afterDelay.ts), so a quick pause and resume
/// draws nothing. By then the account's machine list has been read, so a paused machine never reads
/// "offline" first. Its place is taken from the first frame, as before (empty and out of the
/// accessibility tree until then), so its text fading in moves no row, and it sits above the
/// transcript, never over it.
export function PeerCopyBanner(props: Parameters<typeof PeerCopyBannerBody>[0] & { noteDelayMs?: number }) {
  const { noteDelayMs = RESUME_NOTE_DELAY_MS, ...body } = props;
  const shown = useAfterDelay(true, noteDelayMs);
  return (
    <div className="acpmux-peer-copy-slot" data-shown={shown || undefined}>
      <PeerCopyBannerBody {...body} />
    </div>
  );
}

function PeerCopyBannerBody({
  copy,
  now = Date.now(),
  machine,
  onResume,
  onReconnect,
}: {
  copy: PeerCopyState;
  now?: number;
  machine?: PeerMachineState;
  onResume?(): void;
  onReconnect?(peer: string): Promise<unknown>;
}) {
  const t = useT();
  const [reconnect, setReconnect] = useState<{ state: "idle" | "reconnecting" | "failed"; error?: string }>({
    state: "idle",
  });
  const detail =
    copy.capturedAt !== undefined
      ? t("peerCopy.offline.savedAt", { time: relativeTime(copy.capturedAt, now, currentLanguage()) })
      : t("peerCopy.offline.saved");
  const paused = machine === "paused" && onResume !== undefined;
  const arm = experimentArm(pausedMachineResume);
  const resume = (className: string) => (
    <button type="button" className={className} onClick={onResume}>
      {t("peerCopy.paused.resume")}
    </button>
  );
  if (machine === "starting") {
    return (
      <div className="acpmux-link-missing acpmux-peer-copy" data-enter="top" data-machine="starting">
        <output className="acpmux-peer-copy-title">
          <Spinner size={12} loading className="acpmux-peer-copy-spinner" />
          {t("peerCopy.starting.title", { machine: copy.peer })}
        </output>
        <p className="acpmux-watch-hint">{detail}</p>
      </div>
    );
  }
  if (paused) {
    return (
      <div className="acpmux-link-missing acpmux-peer-copy" data-enter="top" data-machine="paused" data-arm={arm}>
        <p className="acpmux-peer-copy-title">
          <span>{t("peerCopy.paused.title", { machine: copy.peer })}</span>
          {arm === "inline" && resume("acpmux-folder-choice-button")}
          {arm === "button" && resume("acpmux-peer-copy-resume")}
        </p>
        <p className="acpmux-watch-hint">{detail}</p>
        {arm === "actions" && <p className="acpmux-live-chat-actions">{resume("acpmux-folder-choice-button")}</p>}
      </div>
    );
  }
  const reconnectButton = onReconnect ? (
    <button
      type="button"
      className="acpmux-peer-copy-resume"
      disabled={reconnect.state === "reconnecting"}
      data-state={reconnect.state}
      onClick={() => {
        if (reconnect.state === "reconnecting") return;
        setReconnect({ state: "reconnecting" });
        Promise.resolve(onReconnect(copy.peer)).then(
          () => setReconnect({ state: "idle" }),
          (error: unknown) => setReconnect({ state: "failed", error: errorMessage(error) || String(error) }),
        );
      }}
    >
      {t(
        reconnect.state === "reconnecting"
          ? "sessionInfo.connectors.reconnecting"
          : reconnect.state === "failed"
            ? "sessionInfo.connectors.retry"
            : "sessionInfo.connectors.reconnectAction",
      )}
    </button>
  ) : null;
  return (
    <div className="acpmux-link-missing acpmux-peer-copy" data-enter="top">
      <p className="acpmux-peer-copy-title">
        <span>{t("peerCopy.offline.title", { machine: copy.peer })}</span>
        {reconnectButton}
      </p>
      <p className="acpmux-watch-hint">{detail}</p>
      {reconnect.state === "failed" && reconnect.error && (
        <p className="acpmux-watch-hint" role="alert">
          {reconnect.error}
        </p>
      )}
    </div>
  );
}
