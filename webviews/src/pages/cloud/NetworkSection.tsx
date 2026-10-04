// Private networks, this Mac's tunnel, and the firewall rules of the selected machine. Attaching the
// tunnel, a new tunnel key, and every firewall change open a path into a network, so the page never
// calls those ops: the host runs them after its native confirmation (`cmux.app.action.run`). The
// tunnel controls stay minimal and labeled: `cmux link` will own the tunnel of this Mac.
import { useState } from "react";
import { CloudOps, type FirewallEndpoint } from "./ops";
import { isUnavailable, plainKeys, PortField, Unavailable, type SectionProps } from "./sectionParts";
import { L } from "./strings";

function endpoint(value: FirewallEndpoint, t: (key: string) => string): string {
  const where = value.public ? t(L.firewallPublic) : (value.cidr ?? value.vmId ?? value.vpcId ?? value.tunnelId ?? "");
  const port = value.port ? `:${value.port}${value.protocol ? `/${value.protocol}` : ""}` : "";
  return `${where}${port}`;
}

/** Firewall add: an optional source CIDR (empty = anyone) and a TCP port of this machine. */
function FirewallForm({ store, machine, t }: Pick<SectionProps, "store" | "machine"> & { t: (key: string) => string }) {
  const [source, setSource] = useState("");
  const [note, setNote] = useState("");
  const create = (port: number) => {
    const cidr = source.trim();
    const description = note.trim();
    void store.detail.createFirewallRule({
      source: cidr ? { cidr } : { public: true },
      destination: { vmId: machine, port, protocol: "tcp" },
      ...(description ? { description } : {}),
    });
    setSource("");
    setNote("");
  };
  return (
    <PortField
      label={t(L.firewallAdd)}
      button="+"
      inputClass="cloud-firewall-port"
      buttonClass="cloud-firewall-add"
      before={
        <>
          <input
            className="cloud-input cloud-firewall-source"
            placeholder={t(L.firewallSource)}
            aria-label={t(L.firewallSource)}
            value={source}
            onChange={(event) => setSource(event.target.value)}
            onKeyDown={plainKeys(() => undefined)}
          />
          <input
            className="cloud-input cloud-firewall-note"
            placeholder={t(L.firewallDescription)}
            aria-label={t(L.firewallDescription)}
            value={note}
            onChange={(event) => setNote(event.target.value)}
            onKeyDown={plainKeys(() => undefined)}
          />
        </>
      }
      onSubmit={create}
    />
  );
}

export function NetworkSection({ store, machine, detail, unavailable, strings }: SectionProps) {
  const { t } = strings;
  const firewallUnavailable = isUnavailable(unavailable, "firewall");
  return (
    <>
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.network)}</h3>
        {!unavailable.includes(CloudOps.tunnelRotateKey) && (
          <button
            type="button"
            className="cloud-link-button cloud-tunnel-rotate"
            onClick={() => void store.detail.rotateTunnelKey()}
          >
            {t(L.tunnelRotate)}
          </button>
        )}
      </div>
      {isUnavailable(unavailable, "networks") ? (
        <Unavailable t={t} />
      ) : detail.networks?.length ? (
        <>
          <ul className="cloud-items">
            {detail.networks.map((network) => (
              <li key={network.id} className="cloud-item cloud-network">
                <span className="cloud-item-title cloud-mono">{network.cidr ?? network.cidrV6 ?? network.id}</span>
                <span className="cloud-item-detail">
                  {network.scope === "team" ? t(L.accessTeam) : t(L.accessPersonal)}
                </span>
                <span className="cloud-item-actions">
                  {!unavailable.includes(CloudOps.tunnelAttach) && (
                    <button
                      type="button"
                      className="cloud-link-button cloud-tunnel-attach"
                      onClick={() => void store.detail.attachTunnel(network.id)}
                    >
                      {t(L.tunnelAttach)}
                    </button>
                  )}
                </span>
              </li>
            ))}
          </ul>
          <p className="cloud-muted cloud-tunnel-note">{t(L.tunnelNote)}</p>
        </>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.noNetworks)}</p>
      )}
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.firewall)}</h3>
        {!firewallUnavailable && !unavailable.includes(CloudOps.firewallCreate) && (
          <FirewallForm store={store} machine={machine} t={t} />
        )}
      </div>
      {firewallUnavailable ? (
        <Unavailable t={t} />
      ) : detail.firewall?.length ? (
        <ul className="cloud-items">
          {detail.firewall.map((rule) => (
            <li key={rule.id} className="cloud-item cloud-firewall-rule">
              <span className="cloud-item-title">
                {`${t(L.firewallAllow)} ${endpoint(rule.source, t)} → ${endpoint(rule.destination, t)}`}
              </span>
              {rule.description && <span className="cloud-item-detail">{rule.description}</span>}
              <span className="cloud-item-actions">
                <button
                  type="button"
                  className="cloud-link-button destructive"
                  onClick={() => void store.deleteFirewallRule(rule.id)}
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
