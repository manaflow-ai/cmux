// The team's archives: machines the platform deleted (automatic cleanup, or a person's "Archive and
// delete") whose disks it kept as snapshots (`archive_of`). Each row says until when it is kept and
// offers Restore (`cloud.snapshot.restore`, a native action: a new machine from the archive). Hidden
// when there are none.
import type { Strings } from "../shared/i18n";
import { formatDate, formatMegabytes } from "./model";
import type { CloudSnapshot } from "./ops";
import { format, L } from "./strings";

export interface ArchiveListProps {
  archives: readonly CloudSnapshot[];
  strings: Strings;
  /** The page may not change anything now (signed out, link down). */
  disabled?: boolean;
  onRestore: (snapshot: CloudSnapshot) => void;
}

export function ArchiveList({ archives, strings, disabled, onRestore }: ArchiveListProps) {
  const { t, language } = strings;
  if (archives.length === 0) return null;
  return (
    <section className="cloud-archives" aria-label={t(L.archivesTitle)}>
      <h3 className="cloud-subsection-title">{t(L.archivesTitle)}</h3>
      <ul className="cloud-archive-list">
        {archives.map((snapshot) => {
          const archive = snapshot.archive_of!;
          const ready = snapshot.status === "ready";
          return (
            <li key={snapshot.id} className="cloud-archive">
              <span className="cloud-archive-text">
                <span className="cloud-archive-name">{archive.name || archive.machine}</span>
                <span className="cloud-muted cloud-archive-until">
                  {format(t(L.archiveKeptUntil), { date: formatDate(archive.until, language, false) })}
                  {snapshot.size_mb ? ` · ${formatMegabytes(snapshot.size_mb, t, language)}` : ""}
                </span>
              </span>
              <button
                type="button"
                className="cloud-link-button cloud-archive-restore"
                disabled={disabled || !ready}
                onClick={() => onRestore(snapshot)}
              >
                {t(L.archiveRestore)}
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
