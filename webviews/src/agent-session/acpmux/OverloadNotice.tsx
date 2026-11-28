import { useEffect, useState } from "react";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import type { HostOverload } from "./overloadNoticeModel";

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
