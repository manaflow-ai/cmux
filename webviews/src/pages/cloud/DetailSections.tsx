// The snapshots of the selected machine (ports are PortsSection.tsx, files FilesSection.tsx). A
// snapshot counts against the plan's saved limit and a restore makes a new machine, so take, restore
// and delete all go to the host's native confirmation; the section is read again after a yes.
// Restore shows as a pending create in the list. A classic machine lists its snapshots read-only.
// A section whose op the owner does not serve yet shows "Not available yet" and no controls.
import { formatDate } from "./model";
import { CloudOps } from "./ops";
import { isUnavailable, Unavailable, type SectionProps } from "./sectionParts";
import { L } from "./strings";

export function SnapshotsSection({
  store,
  machine,
  detail,
  unavailable,
  strings,
  readOnly,
}: SectionProps & { readOnly?: boolean }) {
  const { t, language } = strings;
  if (isUnavailable(unavailable, "snapshots"))
    return (
      <>
        <h3 className="cloud-subsection-title">{t(L.snapshots)}</h3>
        <Unavailable t={t} />
      </>
    );
  return (
    <>
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.snapshots)}</h3>
        {!readOnly && !unavailable.includes(CloudOps.snapshotCreate) && (
          <button
            type="button"
            className="cloud-link-button cloud-snapshot-create"
            onClick={() => void store.detail.createSnapshot(machine)}
          >
            {t(L.snapshotCreate)}
          </button>
        )}
      </div>
      {detail.snapshots?.length ? (
        <ul className="cloud-items">
          {detail.snapshots.map((snapshot) => (
            <li key={snapshot.id} className="cloud-item cloud-snapshot">
              <span className="cloud-item-title">{snapshot.name || t(L.snapshotUnnamed)}</span>
              <span className="cloud-item-detail">{formatDate(snapshot.created_at, language)}</span>
              {!readOnly && (
                <span className="cloud-item-actions">
                  <button
                    type="button"
                    className="cloud-link-button cloud-snapshot-restore"
                    onClick={() => void store.restoreSnapshot(snapshot)}
                  >
                    {t(L.restore)}
                  </button>
                  <button
                    type="button"
                    className="cloud-link-button destructive cloud-snapshot-delete"
                    onClick={() => void store.deleteSnapshot(snapshot.id)}
                  >
                    {t(L.delete)}
                  </button>
                </span>
              )}
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noSnapshots)}</p>
      )}
    </>
  );
}
