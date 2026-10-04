// Detail sections of the selected machine: snapshots, publications and domains (network and firewall
// are NetworkSection.tsx, ports PortsSection.tsx, files FilesSection.tsx). Deletes and publication
// changes go to the host's native confirmation (detail.ts `native`); other changes call the op with an
// idempotency key and re-read the section after the owner answers. Restore makes a new machine
// (`snapshot.restore`), shown as a pending create in the list. A section whose op the owner does not
// serve yet shows "Not available yet" and no controls.
import { useState } from "react";
import { formatDate } from "./model";
import { CloudOps, type AccessMode } from "./ops";
import { isUnavailable, PortField, stateLabel, Unavailable, type SectionProps } from "./sectionParts";
import { format, L } from "./strings";

export function SnapshotsSection({ store, machine, detail, unavailable, strings }: SectionProps) {
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
        {!unavailable.includes(CloudOps.snapshotCreate) && (
          <button type="button" className="cloud-link-button" onClick={() => void store.detail.createSnapshot(machine)}>
            {t(L.snapshotCreate)}
          </button>
        )}
      </div>
      {detail.snapshots?.length ? (
        <ul className="cloud-items">
          {detail.snapshots.map((snapshot) => (
            <li key={snapshot.id} className="cloud-item cloud-snapshot">
              <span className="cloud-item-title">{snapshot.name || t(L.snapshotUnnamed)}</span>
              <span className="cloud-item-detail">{formatDate(snapshot.createdAt, language)}</span>
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
                  className="cloud-link-button destructive"
                  onClick={() => void store.deleteSnapshot(machine, snapshot.id)}
                >
                  {t(L.delete)}
                </button>
              </span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noSnapshots)}</p>
      )}
    </>
  );
}

const ACCESS_MODES: readonly AccessMode[] = ["personal", "team", "public"];

const AccessLabel: Record<AccessMode, string> = {
  personal: L.accessPersonal,
  team: L.accessTeam,
  public: L.accessPublic,
};

export function PublicationsSection({ store, machine, detail, unavailable, strings }: SectionProps) {
  const { t } = strings;
  // The page always sends the mode it shows, so the native confirmation names the mode that applies.
  const [access, setAccess] = useState<AccessMode>("personal");
  if (isUnavailable(unavailable, "publications"))
    return (
      <>
        <h3 className="cloud-subsection-title">{t(L.publications)}</h3>
        <Unavailable t={t} />
      </>
    );
  return (
    <>
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.publications)}</h3>
        {!unavailable.includes(CloudOps.publicationCreate) && (
          <PortField
            label={t(L.publicationPort)}
            button={t(L.publicationAdd)}
            inputClass="cloud-publication-port"
            buttonClass="cloud-publication-add"
            before={
              <select
                className="cloud-input cloud-publication-access"
                aria-label={t(L.accessMode)}
                value={access}
                onChange={(event) => setAccess(event.target.value as AccessMode)}
              >
                {ACCESS_MODES.map((mode) => (
                  <option key={mode} value={mode}>
                    {t(AccessLabel[mode])}
                  </option>
                ))}
              </select>
            }
            onSubmit={(port) => void store.detail.createPublication(machine, port, access)}
          />
        )}
      </div>
      {detail.publications?.length ? (
        <ul className="cloud-items">
          {detail.publications.map((publication) => (
            <li key={publication.id} className="cloud-item cloud-publication">
              <span className="cloud-item-title cloud-mono">{publication.url || publication.hostname}</span>
              <span className="cloud-item-detail">
                {`${t(L.publicationPort)} ${publication.port} · ${t(AccessLabel[publication.accessMode] ?? L.accessPersonal)} · ${stateLabel(publication.state, t)}`}
              </span>
              <span className="cloud-item-actions">
                {publication.state !== "active" && (
                  <button
                    type="button"
                    className="cloud-link-button"
                    onClick={() => void store.detail.verifyPublication(publication.id)}
                  >
                    {t(L.verify)}
                  </button>
                )}
                <button
                  type="button"
                  className="cloud-link-button destructive cloud-publication-delete"
                  onClick={() => void store.detail.deletePublication(publication.id)}
                >
                  {t(L.delete)}
                </button>
              </span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noPublications)}</p>
      )}
    </>
  );
}

export function DomainsSection({ store, detail, unavailable, strings }: Omit<SectionProps, "machine">) {
  const { t } = strings;
  return (
    <>
      <h3 className="cloud-subsection-title">{t(L.domains)}</h3>
      {isUnavailable(unavailable, "domains") ? (
        <Unavailable t={t} />
      ) : detail.domains?.length ? (
        <ul className="cloud-items">
          {detail.domains.map((domain) => (
            <li key={domain.id} className="cloud-item cloud-domain">
              <span className="cloud-item-title cloud-mono cloud-domain-hostname">{domain.hostname}</span>
              <span className={`cloud-item-detail domain-${domain.verificationState}`}>
                {[
                  stateLabel(domain.verificationState, t),
                  domain.certificateState
                    ? format(t(L.domainCertificate), { state: stateLabel(domain.certificateState, t) })
                    : "",
                  format(t(L.domainPublications), { count: domain.publications.length }),
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </span>
              <span className="cloud-item-actions">
                {domain.verificationState !== "verified" && (
                  <button
                    type="button"
                    className="cloud-link-button"
                    onClick={() => void store.detail.verifyDomain(domain.hostname)}
                  >
                    {t(L.verify)}
                  </button>
                )}
              </span>
              {!!domain.dnsInstructions?.length && (
                <div className="cloud-dns">
                  <span className="cloud-muted">{t(L.domainDns)}</span>
                  {domain.dnsInstructions.map((record, index) => (
                    <code key={index} className="cloud-dns-record cloud-mono">
                      {[record.recordTypes?.join("/"), record.name, record.value].filter(Boolean).join("  ")}
                    </code>
                  ))}
                </div>
              )}
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noDomains)}</p>
      )}
    </>
  );
}
