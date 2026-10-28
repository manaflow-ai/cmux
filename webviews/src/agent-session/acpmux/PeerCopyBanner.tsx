import { relativeTime } from "./conversation/relativeTime";
import { currentLanguage, useT } from "./i18n";
import type { PeerCopyState } from "./peerCopy";

/// A peer chat drawn from the Mac's copy while its machine does not answer (peerCopy.ts): the
/// transcript is what the Mac last saw and may be out of date, until the machine is back and the
/// chat catches up. Drops in from the top of the chat (ui/popupSurface.css `data-enter`), as the
/// watch banner does.
export function PeerCopyBanner({ copy, now = Date.now() }: { copy: PeerCopyState; now?: number }) {
  const t = useT();
  const detail =
    copy.capturedAt !== undefined
      ? t("peerCopy.offline.savedAt", { time: relativeTime(copy.capturedAt, now, currentLanguage()) })
      : t("peerCopy.offline.saved");
  return (
    <div className="acpmux-link-missing acpmux-peer-copy" data-enter="top">
      <p>{t("peerCopy.offline.title", { machine: copy.peer })}</p>
      <p className="acpmux-watch-hint">{detail}</p>
    </div>
  );
}
