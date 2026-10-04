// Detail sections of the selected machine: snapshots, publications, domains, network and firewall.
// Deletes and firewall changes go to the host's native confirmation (detail.ts `native`); other
// changes call the op with an idempotency key and re-read the section after the owner answers.
import { useState, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import type { MachineDetail } from "./detail";
import { formatDate, plain } from "./model";
import type { CloudDomain, FirewallEndpoint } from "./ops";
import type { CloudStore } from "./store";
import { L } from "./strings";

interface SectionProps {
  store: CloudStore;
  machine: string;
  detail: MachineDetail;
  strings: Strings;
}

const DomainLabel: Record<CloudDomain["status"], string> = {
  verified: L.domainVerified,
  pending: L.domainPending,
  failed: L.domainFailed,
};

export function SnapshotsSection({ store, machine, detail, strings }: SectionProps) {
  const { t, language } = strings;
  return (
    <>
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.snapshots)}</h3>
        <button type="button" className="cloud-link-button" onClick={() => void store.detail.createSnapshot(machine)}>
          {t(L.snapshotCreate)}
        </button>
      </div>
      {detail.snapshots?.length ? (
        <ul className="cloud-items">
          {detail.snapshots.map((snapshot) => (
            <li key={snapshot.id} className="cloud-item cloud-snapshot">
              <span className="cloud-item-title">{snapshot.name || t(L.snapshotUnnamed)}</span>
              <span className="cloud-item-detail">{formatDate(snapshot.created_at_ms, language)}</span>
              <span className="cloud-item-actions">
                <button
                  type="button"
                  className="cloud-link-button"
                  onClick={() => void store.detail.restoreSnapshot(machine, snapshot.id)}
                >
                  {t(L.restore)}
                </button>
                <button
                  type="button"
                  className="cloud-link-button"
                  onClick={() => void store.detail.forkSnapshot(machine, snapshot.id)}
                >
                  {t(L.fork)}
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

/** A small number field that submits on plain Return. */
function PortField({ label, onSubmit }: { label: string; onSubmit: (port: number) => void }) {
  const [value, setValue] = useState("");
  const port = Number(value);
  const valid = Number.isInteger(port) && port > 0 && port < 65536;
  const submit = () => {
    if (!valid) return;
    onSubmit(port);
    setValue("");
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (!plain(event) || event.key !== "Enter") return;
    event.preventDefault();
    submit();
  };
  return (
    <span className="cloud-inline-form">
      <input
        className="cloud-input cloud-port-input"
        inputMode="numeric"
        placeholder={label}
        aria-label={label}
        value={value}
        onChange={(event) => setValue(event.target.value.replace(/[^0-9]/g, ""))}
        onKeyDown={onKeyDown}
      />
      <button type="button" className="cloud-button" aria-disabled={!valid} onClick={submit}>
        +
      </button>
    </span>
  );
}

export function PublicationsSection({ store, machine, detail, strings }: SectionProps) {
  const { t } = strings;
  return (
    <>
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.publications)}</h3>
        <PortField
          label={t(L.publicationPort)}
          onSubmit={(port) => void store.detail.createPublication(machine, port)}
        />
      </div>
      {detail.publications?.length ? (
        <ul className="cloud-items">
          {detail.publications.map((publication) => (
            <li key={publication.id} className="cloud-item">
              <span className="cloud-item-title cloud-mono">{publication.hostname}</span>
              <span className="cloud-item-detail">
                {`${t(L.publicationPort)} ${publication.port} · ${t(DomainLabel[publication.status === "active" ? "verified" : publication.status])}`}
              </span>
              <span className="cloud-item-actions">
                {publication.status !== "active" && (
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
                  className="cloud-link-button destructive"
                  onClick={() => void store.detail.deletePublication(machine, publication.id)}
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

export function DomainsSection({ store, detail, strings }: Omit<SectionProps, "machine">) {
  const { t } = strings;
  return (
    <>
      <h3 className="cloud-subsection-title">{t(L.domains)}</h3>
      {detail.domains?.length ? (
        <ul className="cloud-items">
          {detail.domains.map((domain) => (
            <li key={domain.name} className="cloud-item">
              <span className="cloud-item-title cloud-mono">{domain.name}</span>
              <span className={`cloud-item-detail domain-${domain.status}`}>{t(DomainLabel[domain.status])}</span>
              <span className="cloud-item-actions">
                {domain.status !== "verified" && (
                  <button
                    type="button"
                    className="cloud-link-button"
                    onClick={() => void store.detail.verifyDomain(domain.name)}
                  >
                    {t(L.verify)}
                  </button>
                )}
              </span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noDomains)}</p>
      )}
    </>
  );
}

function endpoint(value: FirewallEndpoint, t: (key: string) => string): string {
  const where = value.public
    ? t(L.firewallPublic)
    : (value.cidr ?? value.vm_id ?? value.vpc_id ?? value.tunnel_id ?? "");
  const port = value.port ? `:${value.port}${value.protocol ? `/${value.protocol}` : ""}` : "";
  return `${where}${port}`;
}

export function NetworkSection({ store, machine, detail, strings }: SectionProps) {
  const { t } = strings;
  return (
    <>
      <h3 className="cloud-subsection-title">{t(L.network)}</h3>
      {detail.networks?.length ? (
        <ul className="cloud-items">
          {detail.networks.map((network) => (
            <li key={network.id} className="cloud-item">
              <span className="cloud-item-title cloud-mono">{network.cidr ?? network.cidr_v6 ?? network.id}</span>
              <span className="cloud-item-detail">{network.scope}</span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noNetworks)}</p>
      )}
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.firewall)}</h3>
        <PortField
          label={t(L.firewallAdd)}
          onSubmit={(port) => void store.detail.createFirewallRule(machine, { action: "allow", port, protocol: "tcp" })}
        />
      </div>
      {detail.firewall?.length ? (
        <ul className="cloud-items">
          {detail.firewall.map((rule) => (
            <li key={rule.id} className="cloud-item cloud-firewall-rule">
              <span className="cloud-item-title">
                {`${t(rule.action === "deny" ? L.firewallDeny : L.firewallAllow)} ${endpoint(rule.source, t)} → ${endpoint(rule.destination, t)}`}
              </span>
              {rule.description && <span className="cloud-item-detail">{rule.description}</span>}
              <span className="cloud-item-actions">
                <button
                  type="button"
                  className="cloud-link-button destructive"
                  onClick={() => void store.deleteFirewallRule(machine, rule.id)}
                >
                  {t(L.delete)}
                </button>
              </span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noFirewall)}</p>
      )}
    </>
  );
}
