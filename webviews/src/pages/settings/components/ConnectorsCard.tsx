// Settings > Accounts and Devices > Connectors: the accounts the person lets their agents use, like
// the connectors of a Claude chat. Leo, 2026-11-09: "how about MCPs and the whole, like, connectors
// type situation that ChatGPT has?" and "not everybody necessarily wants to have GitHub connected":
// nothing is connected until the person clicks Connect, and a new connection is theirs alone unless
// they share it with their team. The list is cmux-platform's (`cmux.settings.connectors.list`); the
// provider's own page approves a connection in the browser, and the list is read again when the
// page comes back to the front. Disconnect asks first, inline. It does not poll.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { ChoiceGroup } from "../../../ui/ChoiceGroup";
import { GitHubMark } from "../../../agent-session/acpmux/conversation/icons";
import { useStore } from "../context";
import { CONNECTORS_KEY, connectorsQuery } from "../sectionQueries";
import {
  connectorRows,
  connectorsOffered,
  connectorsPending,
  type AvailableRow,
  type ConnectedRow,
} from "../connectors";
import { t } from "../strings";

type Sharing = "private" | "team";

export function ConnectorsCard() {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(connectorsQuery(store));
  const state = query.data ?? null;
  const rows = connectorRows(state);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [opened, setOpened] = useState(false);
  const refresh = () => queryClient.invalidateQueries({ queryKey: CONNECTORS_KEY });
  // A connection finishes in the browser: read the list again when the person comes back, only
  // while one is waiting. The listener goes with the wait (or the card).
  const waiting = opened || connectorsPending(rows);
  useEffect(() => {
    if (!waiting) return;
    const back = () => {
      if (document.visibilityState === "visible") void refresh();
    };
    window.addEventListener("focus", back);
    document.addEventListener("visibilitychange", back);
    return () => {
      window.removeEventListener("focus", back);
      document.removeEventListener("visibilitychange", back);
    };
  });
  const run = async (
    gesture:
      | { action: "connect"; provider: string; sharing: Sharing }
      | { action: "disconnect"; provider: string; connection: string },
  ) => {
    setBusy(true);
    try {
      const refused = await store.runConnector(gesture);
      setError(refused);
      if (gesture.action === "connect") setOpened(refused === null);
      await refresh();
    } finally {
      setBusy(false);
    }
  };
  const drawn = query.isFetched;
  const message = !drawn
    ? null
    : !connectorsOffered(state)
      ? t("settingsPage.connectors.unavailable")
      : state.signedIn === false
        ? t("settingsPage.connectors.signIn")
        : (state.error ?? null);
  return (
    <section className="group" data-card="connectors" id="connectors" aria-busy={busy}>
      <h3 className="group-title">{t("settingsPage.connectors.title")}</h3>
      <div className="row-help">{t("settingsPage.connectors.intro")}</div>
      <div className="rows">
        {message ? (
          <div className="row" data-connectors-message="">
            <span className="row-help">{message}</span>
          </div>
        ) : (
          drawn && (
            <ConnectorsList
              connected={rows.connected}
              available={rows.available}
              team={Boolean(state?.team)}
              busy={busy}
              onConnect={(provider, sharing) => void run({ action: "connect", provider, sharing })}
              onDisconnect={(row) => void run({ action: "disconnect", provider: row.provider, connection: row.id })}
            />
          )
        )}
      </div>
      {opened && !error && (
        <output className="row-help" data-connectors-opened="">
          {t("settingsPage.connectors.opened")}
        </output>
      )}
      {error && (
        <div className="row-error" role="alert" data-connectors-error="">
          {t("settingsPage.connectors.failed", error)}
        </div>
      )}
    </section>
  );
}

/** A provider's mark: GitHub's logo, else its initial (no third-party artwork is bundled). */
function ConnectorMark({ provider, name }: { provider: string; name: string }) {
  return (
    <span className="accounts-mark connectors-mark" aria-hidden="true" data-connector-mark={provider}>
      {provider === "github" ? (
        <GitHubMark size={16} />
      ) : (
        <span className="connectors-initial">{name.slice(0, 1)}</span>
      )}
    </span>
  );
}

/** The line under a connection: its account, who may use it, and anything it waits on. */
export function connectedDetail(row: ConnectedRow): string {
  const parts: string[] = [];
  if (row.account) parts.push(row.account);
  parts.push(
    t(row.sharing === "team" ? "settingsPage.connectors.sharingTeam" : "settingsPage.connectors.sharingPrivate"),
  );
  if (row.status !== "active") parts.push(t(`settingsPage.connectors.status.${row.status}`));
  return parts.join(" · ");
}

/** How the list draws (gallery `settings.connectors-layouts`). `grouped`, the shipped one: what is
 * connected, then what can be, each a Settings row (mark, name over one detail line, one trailing
 * control). `catalog` is one row per provider whatever its state, like an app store; `tiles` is a
 * grid of provider tiles, one card each. */
export type ConnectorsLayout = "grouped" | "catalog" | "tiles";

export function ConnectorsList({
  connected,
  available,
  team,
  busy,
  onConnect,
  onDisconnect,
  layout = "grouped",
}: {
  connected: ConnectedRow[];
  available: AvailableRow[];
  /** A team is selected: Connect asks who may use the new connection. */
  team: boolean;
  busy: boolean;
  onConnect: (provider: string, sharing: Sharing) => void;
  onDisconnect: (row: ConnectedRow) => void;
  layout?: ConnectorsLayout;
}) {
  const [asking, setAsking] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  // The connection whose details are open: Disconnect lives there, not on every row.
  const [open, setOpen] = useState<string | null>(null);
  const connect = (provider: string) => (team ? setAsking(provider) : onConnect(provider, "private"));
  const connectButton = (row: AvailableRow) =>
    row.configured ? (
      <Button
        className="button"
        data-connector-action="connect"
        aria-label={t("settingsPage.connectors.connectProvider", row.name)}
        disabled={busy || asking === row.provider}
        onClick={() => connect(row.provider)}
      >
        {t("settingsPage.connectors.connect")}
      </Button>
    ) : (
      <span className="row-help" data-connector-unconfigured="">
        {t("settingsPage.connectors.notSetUp")}
      </span>
    );
  const detailsToggle = (row: ConnectedRow) => (
    <Button
      className="button"
      data-connector-action="details"
      aria-expanded={open === row.id}
      aria-label={t("settingsPage.connectors.detailsProvider", row.name)}
      onClick={() => {
        setConfirming(null);
        setOpen(open === row.id ? null : row.id);
      }}
    >
      {t(open === row.id ? "settingsPage.connectors.hideDetails" : "settingsPage.connectors.details")}
    </Button>
  );
  // The open connection's details: who may use it, then Disconnect (asked first), or why it is not theirs.
  const details = (row: ConnectedRow) =>
    open === row.id && (
      <div className="accounts-body" data-connection-details="">
        <span className="row-help">
          {t(
            row.sharing === "team"
              ? "settingsPage.connectors.sharingTeamHelp"
              : "settingsPage.connectors.sharingPrivateHelp",
          )}
        </span>
        {!row.canDisconnect ? (
          <span className="row-help">{t("settingsPage.connectors.notYours")}</span>
        ) : confirming === row.id ? (
          <>
            <output className="row-help" data-connector-confirm="">
              {t("settingsPage.connectors.disconnectConfirm")}
            </output>
            <span className="accounts-buttons">
              <Button
                danger
                className="button"
                data-connector-action="confirmDisconnect"
                disabled={busy}
                onClick={() => {
                  setConfirming(null);
                  setOpen(null);
                  onDisconnect(row);
                }}
              >
                {t("settingsPage.connectors.disconnect")}
              </Button>
              <Button className="button" onClick={() => setConfirming(null)}>
                {t("settingsPage.cancel")}
              </Button>
            </span>
          </>
        ) : (
          <span className="accounts-buttons">
            <Button
              danger
              className="button"
              data-connector-action="disconnect"
              aria-label={t("settingsPage.connectors.disconnectProvider", row.name)}
              disabled={busy}
              onClick={() => setConfirming(row.id)}
            >
              {t("settingsPage.connectors.disconnect")}
            </Button>
          </span>
        )}
      </div>
    );
  const sharingForm = (row: AvailableRow) =>
    asking === row.provider && (
      <SharingChoice
        name={row.name}
        busy={busy}
        onSubmit={(sharing) => {
          setAsking(null);
          onConnect(row.provider, sharing);
        }}
        onCancel={() => setAsking(null)}
      />
    );
  if (layout === "tiles") {
    return (
      <div className="connectors-tiles">
        {[
          ...connected.map((row) => ({ kind: "connected" as const, row })),
          ...available.map((row) => ({ kind: "available" as const, row })),
        ].map((item) => (
          <div
            className="connectors-tile"
            key={item.kind === "connected" ? item.row.id : `add-${item.row.provider}`}
            data-connector={item.row.provider}
          >
            <ConnectorMark provider={item.row.provider} name={item.row.name} />
            <div className="row-title">{item.row.name}</div>
            <div className="row-help">
              {item.kind === "connected"
                ? connectedDetail(item.row)
                : t(`settingsPage.connectors.about.${item.row.provider}`)}
            </div>
            {item.kind === "connected" ? details(item.row) : sharingForm(item.row)}
            <div className="row-control">
              {item.kind === "connected" ? detailsToggle(item.row) : connectButton(item.row)}
            </div>
          </div>
        ))}
      </div>
    );
  }

  const connectedRow = (row: ConnectedRow) => (
    <div
      className="row accounts-row"
      key={row.id}
      data-connector={row.provider}
      data-connection={row.id}
      data-connection-status={row.status}
    >
      <div className="row-main">
        <ConnectorMark provider={row.provider} name={row.name} />
        <div className="row-label">
          <div className="row-title">{row.name}</div>
          <div className="row-help" data-connection-detail="">
            {connectedDetail(row)}
          </div>
        </div>
        <div className="row-control">{detailsToggle(row)}</div>
      </div>
      {details(row)}
    </div>
  );
  const availableRow = (row: AvailableRow) => (
    <div
      className="row accounts-row"
      key={`add-${row.provider}`}
      data-connector={row.provider}
      data-connector-available=""
    >
      <div className="row-main">
        <ConnectorMark provider={row.provider} name={row.name} />
        <div className="row-label">
          <div className="row-title">{row.name}</div>
          <div className="row-help">{t(`settingsPage.connectors.about.${row.provider}`)}</div>
        </div>
        <div className="row-control">{connectButton(row)}</div>
      </div>
      {sharingForm(row) && <div className="accounts-body">{sharingForm(row)}</div>}
    </div>
  );

  if (layout === "catalog") {
    // One row per provider, in the platform's order: its connections, else its Connect.
    const providers = [...new Set([...connected.map((row) => row.provider), ...available.map((row) => row.provider)])];
    return (
      <>
        {providers.flatMap((provider) => {
          const mine = connected.filter((row) => row.provider === provider);
          const add = available.find((row) => row.provider === provider);
          return [...mine.map(connectedRow), ...(add && mine.length === 0 ? [availableRow(add)] : [])];
        })}
      </>
    );
  }

  return (
    <>
      {connected.length > 0 && (
        <div className="row connectors-heading" data-connectors-group="connected">
          <span className="row-help">{t("settingsPage.connectors.connected")}</span>
        </div>
      )}
      {connected.map(connectedRow)}
      {available.length > 0 && (
        <div className="row connectors-heading" data-connectors-group="available">
          <span className="row-help">{t("settingsPage.connectors.available")}</span>
        </div>
      )}
      {available.map(availableRow)}
    </>
  );
}

/** Who may use a new connection: only the person (the default), or their team. */
function SharingChoice({
  name,
  busy,
  onSubmit,
  onCancel,
}: {
  name: string;
  busy: boolean;
  onSubmit: (sharing: Sharing) => void;
  onCancel: () => void;
}) {
  const [sharing, setSharing] = useState<Sharing>("private");
  const group = useId();
  const label = t("settingsPage.connectors.whoTitle", name);
  const form = useRef<HTMLDivElement>(null);
  // Opened by Connect, which it disables: scroll it into view (no animation) and put focus on the
  // checked choice, so the question is never off screen or behind a dead button.
  useEffect(() => {
    form.current?.scrollIntoView?.({ block: "nearest" });
    form.current?.querySelector<HTMLInputElement>("input:checked")?.focus({ preventScroll: true });
  }, []);
  return (
    <div className="accounts-form" data-connector-sharing="" ref={form}>
      <ChoiceGroup label={label} busy={busy} onSubmit={() => onSubmit(sharing)} onCancel={onCancel}>
        <div className="row-title">{label}</div>
        {(["private", "team"] as const).map((value) => (
          <label className="connectors-choice" key={value}>
            <input
              type="radio"
              name={group}
              value={value}
              aria-labelledby={`${group}-${value}`}
              checked={sharing === value}
              onChange={() => setSharing(value)}
            />
            <span>
              <span className="row-title" id={`${group}-${value}`}>
                {t(value === "team" ? "settingsPage.connectors.sharingTeam" : "settingsPage.connectors.sharingPrivate")}
              </span>
              <span className="row-help">
                {t(
                  value === "team"
                    ? "settingsPage.connectors.sharingTeamHelp"
                    : "settingsPage.connectors.sharingPrivateHelp",
                )}
              </span>
            </span>
          </label>
        ))}
      </ChoiceGroup>
      <div className="accounts-buttons">
        <Button
          className="button"
          data-connector-action="confirmConnect"
          disabled={busy}
          onClick={() => onSubmit(sharing)}
        >
          {t("settingsPage.connectors.connect")}
        </Button>
        <Button className="button" onClick={onCancel}>
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </div>
  );
}
