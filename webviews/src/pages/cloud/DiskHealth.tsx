import type { Strings } from "../shared/i18n";
import { useCallback } from "react";
import { useDeadlineNow } from "../../ui/pageClock";
// The theme route that carries Settings > Advanced > Experiments to this page (no agent bridge here).
import "../../experiments/hostSettings";
import { useExperimentSwitch } from "../../experiments/switches";
import { DiskBar } from "./DiskBar";
import { DISK_HEALTH_MAX_AGE_MS, diskHealthState, formatMegabytes } from "./model";
import type { CloudDiskHealth } from "./ops";
import { L } from "./strings";

interface DiskHealthProps {
  health: CloudDiskHealth | null | undefined;
  strings: Strings;
  compact?: boolean;
}

/** `experiments.cloudDiskBar` (off by default): the bar, used over allocated split into system,
 * project and caches (RFD 0068). Off, the summary is today's. */
export const CLOUD_DISK_BAR_SWITCH = "cloudDiskBar";

/** A compact row summary or the full overview for the selected machine. */
export function DiskHealthSummary({ health, strings, compact = false }: DiskHealthProps) {
  const barOn = useExperimentSwitch(CLOUD_DISK_BAR_SWITCH);
  const observedAt = health?.observed_at;
  const next = useCallback(
    (now: number) =>
      typeof observedAt === "number"
        ? Math.max(now + 1, observedAt + DISK_HEALTH_MAX_AGE_MS)
        : Number.POSITIVE_INFINITY,
    [observedAt],
  );
  const now = useDeadlineNow(next);
  const state = diskHealthState(health, now);
  const { t } = strings;
  // The bar needs only the sizes (the relay's `bar`), not the health fields, so it draws even
  // where the health is unknown.
  const bar =
    barOn && health?.bar && health.bar.state !== "allocated" ? (
      <DiskBar bar={health.bar} strings={strings} compact={compact} />
    ) : null;
  if (state === "unknown" && bar) {
    return (
      <span className="cloud-disk-health" data-testid="cloud-disk-health">
        {bar}
      </span>
    );
  }
  if (state === "unknown") {
    return <span className="cloud-disk-health cloud-disk-health-unknown">{t(L.diskDataUnavailable)}</span>;
  }
  if (state === "stale") {
    return <span className="cloud-disk-health cloud-disk-health-stale">{t(L.diskDataStale)}</span>;
  }
  const { language } = strings;
  const value = (mb: number) => formatMegabytes(mb, t, language);
  const topUsers = (health?.top_users ?? []).slice(0, 3);
  return (
    <span className={`cloud-disk-health cloud-disk-health-${state}`} data-testid="cloud-disk-health">
      {bar}
      <span className="cloud-disk-health-capacity">
        {state === "warning" && <strong>{t(L.diskLowSpace)} · </strong>}
        {t(L.diskFree)} {value(health!.free_mb)} · {t(L.diskUsed)} {value(health!.used_mb)} / {value(health!.total_mb)}
      </span>
      {!compact && (
        <>
          <span className="cloud-disk-health-floor">
            {" "}
            · {t(L.diskFloor)} {value(health!.floor_mb)}
          </span>
          {topUsers.length > 0 && (
            <span className="cloud-disk-health-users">
              <span className="cloud-disk-health-users-label"> · {t(L.diskTopUsers)} </span>
              {topUsers.map((user, index) => (
                <span key={`${user.path}-${index}`} className="cloud-disk-health-user">
                  {index > 0 ? ", " : ""}
                  <code>{user.path}</code> ({value(user.used_mb)})
                </span>
              ))}
            </span>
          )}
        </>
      )}
    </span>
  );
}
