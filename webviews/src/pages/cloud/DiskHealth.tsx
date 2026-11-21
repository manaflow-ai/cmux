import type { Strings } from "../shared/i18n";
import { diskHealthState, formatMegabytes } from "./model";
import type { CloudDiskHealth } from "./ops";

interface DiskHealthProps {
  health: CloudDiskHealth | null | undefined;
  strings: Strings;
  compact?: boolean;
}

/** A compact row summary or the full overview for the selected machine. */
export function DiskHealthSummary({ health, strings, compact = false }: DiskHealthProps) {
  const state = diskHealthState(health);
  if (state === "unknown") {
    return <span className="cloud-disk-health cloud-disk-health-unknown">Disk data unavailable</span>;
  }
  if (state === "stale") {
    return <span className="cloud-disk-health cloud-disk-health-stale">Disk data is stale</span>;
  }
  const { t, language } = strings;
  const value = (mb: number) => formatMegabytes(mb, t, language);
  const topUsers = (health?.top_users ?? []).slice(0, 3);
  return (
    <span className={`cloud-disk-health cloud-disk-health-${state}`} data-testid="cloud-disk-health">
      <span className="cloud-disk-health-capacity">
        {state === "warning" && <strong>Low disk space · </strong>}
        Free {value(health!.free_mb)} · Used {value(health!.used_mb)} / {value(health!.total_mb)}
      </span>
      {!compact && (
        <>
          <span className="cloud-disk-health-floor"> · Floor {value(health!.floor_mb)}</span>
          {topUsers.length > 0 && (
            <span className="cloud-disk-health-users">
              <span className="cloud-disk-health-users-label"> · Top users </span>
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
