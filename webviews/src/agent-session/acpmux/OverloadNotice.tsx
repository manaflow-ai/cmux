import { useEffect, useState } from "react";
import { useComposerSettings } from "./composerSettings";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { type HostOverload, OVERLOAD_POLL_MS, readHostOverload } from "./overloadNoticeModel";

/// Polls acpmux for this machine's overload verdict while the page is shown. No `read` (the
/// Developer Tools setting `developerTools.overloadNotice` is off, the default) asks nothing and
/// forgets the last verdict, so the banner goes as soon as the setting does.
export function useHostOverload(read: (() => Promise<unknown>) | undefined): HostOverload | undefined {
  const [state, setState] = useState<HostOverload>();
  useEffect(() => {
    if (!read) {
      setState(undefined);
      return;
    }
    let stopped = false;
    const poll = () => {
      if (typeof document !== "undefined" && document.visibilityState === "hidden") return;
      read().then(
        (value) => !stopped && setState(readHostOverload(value)),
        () => undefined,
      );
    };
    poll();
    const timer = setInterval(poll, OVERLOAD_POLL_MS);
    return () => {
      stopped = true;
      clearInterval(timer);
    };
  }, [read]);
  return state;
}

/// The chat's overload verdict, asked only while Settings > Advanced > Developer Tools >
/// Overload Warning in Chats (`developerTools.overloadNotice`, the composer event's
/// `showOverloadNotice`) is on. Off by default (https://github.com/manaflow-ai/cmux/issues/56156:
/// "this should not be on default"): `read` is never called and no banner shows.
export function usePaneHostOverload(read: () => Promise<unknown>): HostOverload | undefined {
  const { showOverloadNotice } = useComposerSettings();
  return useHostOverload(showOverloadNotice ? read : undefined);
}

/// "This Mac is overloaded: load 290 on 15 cores, swap 95%" above the composer, dismissible. A
/// dismissal holds while the machine stays overloaded; once it has been within its limits, the next
/// overload warns again. Its words only: acpmux decided (host_overload.rs).
export function OverloadNotice({ state }: { state: HostOverload | undefined }) {
  const t = useT();
  const [dismissed, setDismissed] = useState(false);
  const over = state?.overloaded === true;
  useEffect(() => {
    if (!over) setDismissed(false);
  }, [over]);
  const parts = [
    state?.load1 !== undefined && state.loadOver
      ? t("overload.load", { load: Math.round(state.load1), cores: state.cores })
      : undefined,
    state?.swapPercent !== undefined && state.swapOver ? t("overload.swap", { percent: state.swapPercent }) : undefined,
  ].filter(Boolean);
  return (
    <Notice id="host-overload" tier="status" when={over && !dismissed}>
      <output className="acpmux-host-error acpmux-overload-notice" data-overload="">
        <div className="acpmux-host-error-card">
          <p className="acpmux-host-error-message">{t("overload.message", { numbers: parts.join(", ") })}</p>
          <div className="acpmux-host-error-actions">
            <button type="button" data-notice-action="dismiss" onClick={() => setDismissed(true)}>
              {t("overload.dismiss")}
            </button>
          </div>
        </div>
      </output>
    </Notice>
  );
}
