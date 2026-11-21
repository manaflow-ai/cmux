import type { Strings } from "../shared/i18n";
import { useCallback } from "react";
import { useDeadlineNow } from "../../ui/pageClock";
import { DISK_HEALTH_MAX_AGE_MS, diskHealthState, formatMegabytes } from "./model";
import type { CloudDiskHealth } from "./ops";
import { L } from "./strings";

interface DiskHealthProps {
  health: CloudDiskHealth | null | undefined;
  strings: Strings;
  compact?: boolean;
}

/** A compact row summary or the full overview for the selected machine. */
export function DiskHealthSummary({ health, strings, compact = false }: DiskHealthProps) {
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
