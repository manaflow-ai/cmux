// This Mac's port forwards to the selected machine (`cloud.port.*`) and "Open in browser"
// (`cloud.browser.open`). A forward shows the 127.0.0.1 port the owner answered. The browser route
// answers a URL and a proxy; the browser host owns tabs, so the page asks the host for a CEF tab
// whose machine store carries the proxy (`HostActions.browserTabOpen`). Until the host serves that,
// the URL shows with "Not available yet"; a typed refusal shows a message and nothing opens.
import { HostActions } from "./ops";
import { isUnavailable, PortField, Unavailable, type SectionProps } from "./sectionParts";
import { format, L } from "./strings";

function shareExpiry(expiresAt: number | undefined, language: string): string | undefined {
  if (expiresAt === undefined) return undefined;
  // Native and the mock use Unix milliseconds; accepting seconds keeps the
  // display correct if the platform DTO is decoded from its Unix timestamp.
  const date = new Date(expiresAt < 10_000_000_000 ? expiresAt * 1000 : expiresAt);
  if (Number.isNaN(date.getTime())) return undefined;
  return new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

export function PortsSection({
  store,
  machine,
  title,
  detail,
  unavailable,
  strings,
}: SectionProps & { title: string }) {
  const { t } = strings;
  const browser = detail.browser?.machine === machine ? detail.browser : undefined;
  return (
    <>
      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.ports)}</h3>
        {!isUnavailable(unavailable, "ports") && (
          <PortField
            key={`${machine}:${store.detail.epoch}`}
            pending={detail.pendingPorts?.some((pending) => pending.action === "forward")}
            busyLabel={t(L.loading)}
            label={t(L.portsForward)}
            button="+"
            inputClass="cloud-forward-port"
            buttonClass="cloud-forward-add"
            onSubmit={(port) => store.detail.forwardPort(machine, port)}
          />
        )}
      </div>
      {isUnavailable(unavailable, "ports") ? (
        <Unavailable t={t} />
      ) : detail.ports?.length ? (
        <ul className="cloud-items">
          {detail.ports.map((forward) => {
            const pending = detail.pendingPorts?.find((pending) => pending.port === forward.port);
            const shared = detail.sharedPreviews?.[forward.port];
            const expiry = shareExpiry(shared?.expiresAt, strings.language);
            return (
              <li key={forward.port} className="cloud-item cloud-forward">
                <span className="cloud-item-title cloud-mono">
                  {`${forward.port} → `}
                  <span className="cloud-forward-local">{`${forward.host}:${forward.localPort}`}</span>
                </span>
                <span className={`cloud-item-detail forward-${forward.state}`}>
                  {pending ? (
                    <output>{t(L.loading)}</output>
                  ) : (
                    [forward.state === "up" ? t(L.portsUp) : t(L.portsDown), forward.reason].filter(Boolean).join(" · ")
                  )}
                </span>
                <span className="cloud-item-actions">
                  <button
                    type="button"
                    className="cloud-link-button cloud-forward-browser"
                    disabled={!!pending}
                    aria-busy={pending?.action === "browser"}
                    onClick={() => void store.detail.openBrowser(machine, forward.port, title)}
                  >
                    {t(L.openBrowser)}
                  </button>
                  {shared ? (
                    <button
                      type="button"
                      className="cloud-link-button cloud-forward-revoke"
                      disabled={!!pending}
                      aria-busy={pending?.action === "revoke"}
                      onClick={() => void store.detail.revokePreview(machine, forward.port, shared.linkId)}
                    >
                      {t(L.revokeShare)}
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="cloud-link-button cloud-forward-share"
                      disabled={!!pending}
                      aria-busy={pending?.action === "share"}
                      onClick={() => void store.detail.sharePreview(machine, forward.port)}
                    >
                      {t(L.sharePreview)}
                    </button>
                  )}
                  <button
                    type="button"
                    className="cloud-link-button cloud-forward-close"
                    disabled={!!pending}
                    aria-busy={pending?.action === "close"}
                    onClick={() => void store.detail.closePort(machine, forward.port)}
                  >
                    {t(L.portsClose)}
                  </button>
                </span>
                {shared && (
                  <output className="cloud-preview-share-status">
                    {t(L.shareCopied)}
                    {expiry && ` · ${format(t(L.shareExpires), { date: expiry })}`}
                  </output>
                )}
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.portsEmpty)}</p>
      )}
      {browser && (
        <div className="cloud-browser-route">
          <code className="cloud-mono cloud-browser-url">{browser.url}</code>
          <span className="cloud-muted">
            {format(t(L.browserProxy), { address: `${browser.proxy.host}:${browser.proxy.port}` })}
          </span>
          {detail.browserRefused ? (
            <output className="cloud-browser-refused">{t(L.browserTabRefused)}</output>
          ) : (
            unavailable.includes(HostActions.browserTabOpen) && (
              <span className="cloud-muted cloud-unavailable">{t(L.browserTabUnavailable)}</span>
            )
          )}
        </div>
      )}
    </>
  );
}
