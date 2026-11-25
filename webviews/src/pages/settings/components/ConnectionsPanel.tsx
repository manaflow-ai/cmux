// Settings > Integrations > Connections: the remote MCP servers a person connects once in cmux, whose tools every
// agent chat then gets through cmux's hosted MCP server (SettingsConnections in the app; cmux-tui
// cli/mcp_servers.rs writes every label this card shows). On top, All connections lists every
// connection the person has (AllConnections.tsx). The catalog is a grid in rank order: each tile is the
// shared connect card (agent-session/acpmux/ConnectCard.tsx, the one Claude and Codex use) with the
// server's mark, title, one line, a status pill (shared/connect/ConnectPill.tsx) and one button
// (Connect, Reconnect, Turn on; Disconnect behind a confirm), or one line saying why it is not
// available. A connected tile whose sign-in lapses within days (the catalog's `expiresAt`) says when
// and offers Reconnect. Connect opens the provider's sign-in page in the
// system browser with a link back here; the card reads the catalog again when the window comes
// back, on that link, and every few seconds for a minute after Connect. A key-auth server takes one
// pasted key, sent once to the host and cleared here. With a team, Connect asks whose it is.
//
// Leo, 2026-11-24: "i think we might as well just go ahead and add a bunch of integrations into our
// app that people would want... we can just set up allllll the backend shit and whatever may be
// useful.... just code up and merge the ones we care about if they dont already exist"
import { useCallback, useEffect, useId, useRef, useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useSettingsState, useStore, useRowState } from "../context";
import type { ConnectionEntry, ConnectionsRun, ConnectionsState } from "../ops";
import { t } from "../strings";
import { ConnectCard } from "../../../agent-session/acpmux/ConnectCard";
import { CONNECT_IDLE } from "../../../agent-session/acpmux/claudeConnect";
import "../paneStrings";
import { ConnectPill } from "../../shared/connect/ConnectPill";
import { expiryText } from "../../shared/connect/connectStatus";
import { useConnectStrings } from "../../shared/connect/strings";
import { AllConnections, tileStatus } from "./AllConnections";

/** The Labs toggle that lists the servers which cannot be connected yet (Slack, Google). */
export const UPCOMING_KEY = "labs.connectionsUpcoming";

/** How often, and how long, the card reads the catalog again after Connect opened a sign-in page. */
export const CONNECT_POLL_MS = 2000;
export const CONNECT_POLL_FOR_MS = 60_000;

const SELECT_CLASS =
  "box-border h-7 rounded-md border border-solid border-edge bg-transparent px-2 font-[inherit] text-control text-fg outline-none focus:border-accent-soft";

type Gesture = Exclude<ConnectionsRun, { action: "refresh" }>;
type Run = (run: Gesture) => Promise<void>;
/** Whose a new connection is: the person's, or their active team's. */
type Owner = { owner: "me" | "team"; team?: string };
/** A tile's one button: its words, its `data-connect-action` name, and what it runs. */
type Primary = { button: string; action: string; run: () => Promise<void> };

function KeyForm({
  entry,
  busy,
  onConnect,
}: {
  entry: ConnectionEntry;
  busy: boolean;
  onConnect: (key: string) => void;
}) {
  const [key, setKey] = useState("");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const pasted = key.trim();
    // The key goes to the host once and leaves the page's state at once.
    setKey("");
    if (pasted) onConnect(pasted);
  };
  return (
    <form className="connections-key" data-connections-key={entry.name} onSubmit={submit}>
      <Input
        className="field keys-field"
        type="password"
        autoComplete="off"
        spellCheck={false}
        aria-label={t("settingsWindow.connections.keyField", entry.title)}
        placeholder={t("settingsWindow.connections.keyPlaceholder")}
        value={key}
        data-connections-key-field=""
        onChange={(event) => setKey(event.target.value)}
      />
      <Button
        type="submit"
        variant="solid"
        className="button"
        data-connections-action="connectKey"
        disabled={!key || busy}
      >
        {t("settingsWindow.connections.connect")}
      </Button>
    </form>
  );
}

/** The mark of a server without one of its own: the first letter of its title. */
function Monogram({ title }: { title: string }) {
  return (
    <span className="connections-monogram" aria-hidden="true">
      {(title.trim()[0] ?? "?").toUpperCase()}
    </span>
  );
}

/** Disconnect: the first click asks inline, naming what the agents lose; the second removes it. */
function Disconnect({ entry, id, busy, onRun }: { entry: ConnectionEntry; id: string; busy: boolean; onRun: Run }) {
  const [confirming, setConfirming] = useState(false);
  if (!confirming)
    return (
      <Button
        danger
        variant="ghost"
        className="button"
        data-connections-action="remove"
        disabled={busy}
        onClick={() => setConfirming(true)}
      >
        {t("settingsWindow.connections.disconnect")}
      </Button>
    );
  return (
    <div className="connections-confirm" data-connections-confirm="">
      <div className="row-help">{t("settingsWindow.connections.disconnectBody", entry.title)}</div>
      <div className="accounts-buttons">
        <Button
          danger
          variant="ghost"
          className="button"
          data-connections-action="confirmRemove"
          disabled={busy}
          onClick={() => {
            setConfirming(false);
            void onRun({ action: "remove", id });
          }}
        >
          {t("settingsWindow.connections.disconnect")}
        </Button>
        <Button className="button" data-connections-action="cancel" onClick={() => setConfirming(false)}>
          {t("settingsWindow.hub.cancel")}
        </Button>
      </div>
    </div>
  );
}

/** One server as the shared connect card (agent-session/acpmux/ConnectCard.tsx `provider`), its pill
 * from the catalog's state (AllConnections.tsx `tileStatus`). */
function Tile({
  entry,
  busy,
  pending,
  owner,
  onRun,
}: {
  entry: ConnectionEntry;
  busy: boolean;
  pending: boolean;
  owner: Owner;
  onRun: Run;
}) {
  const connectStrings = useConnectStrings();
  const id = entry.connectionId;
  const connect = (key?: string) => onRun({ action: "connect", name: entry.name, ...owner, ...(key ? { key } : {}) });
  const detail = [entry.ownerLabel, entry.state === "connected" ? null : entry.toolsLabel].filter(
    (part): part is string => !!part,
  );
  const status = tileStatus(entry, pending);
  // A lapsing sign-in says when, and its one action is Reconnect before it stops working.
  const lapsing = entry.state === "connected" && (status === "expiring" || status === "reauth") && entry.expiresAt;
  const reconnect = (label: string): Primary | null =>
    id ? { button: label, action: "reconnect", run: () => onRun({ action: "reconnect", id }) } : null;
  const primary: Primary | null =
    entry.state === "connect" && !entry.keyField
      ? { button: t("settingsWindow.connections.connect"), action: "connect", run: () => connect() }
      : entry.state === "reconnect"
        ? reconnect(entry.buttonLabel ?? t("settingsWindow.connections.reconnect"))
        : entry.state === "enable" && id
          ? {
              button: entry.buttonLabel ?? t("settingsWindow.connections.enable"),
              action: "enable",
              run: () => onRun({ action: "enable", id }),
            }
          : lapsing
            ? reconnect(t("settingsWindow.connections.reconnect"))
            : null;
  const pill = (
    <ConnectPill
      status={status}
      label={
        entry.state === "unavailable"
          ? t("settingsWindow.connections.unavailable")
          : lapsing || pending || entry.state === "connect"
            ? null
            : entry.statusLabel
      }
      hint={lapsing ? expiryText(lapsing, navigator.language) : undefined}
      dataPrefix="connections"
    />
  );
  const details = (
    <>
      {entry.state === "unavailable" && entry.statusLabel && (
        <div className="row-help connections-why" data-connections-why="">
          {entry.statusLabel}
        </div>
      )}
      {detail.length > 0 && <div className="row-help connections-detail">{detail.join(" · ")}</div>}
      {lapsing && (
        <div className="row-help" data-connections-expiry={status}>
          {connectStrings.format(
            status === "reauth" ? "connect.expired.detail" : "connect.expiring.detail",
            expiryText(lapsing, navigator.language),
          )}
        </div>
      )}
      {pending && (
        <div className="row-help" data-connections-pending="">
          {t("settingsWindow.connections.waiting")}
        </div>
      )}
    </>
  );
  return (
    <div
      className="connections-tile"
      data-connections-entry={entry.name}
      data-connections-state={entry.state}
      data-connections-tone={status}
      data-connections-loopback={entry.loopback ? "" : undefined}
      data-connections-upcoming={entry.upcoming ? "" : undefined}
    >
      <ConnectCard
        look="card"
        progress={CONNECT_IDLE}
        provider={{
          mark: <Monogram title={entry.title} />,
          title: entry.title,
          line: entry.line,
          button: primary?.button ?? "",
          action: primary?.action,
          disabled: busy,
        }}
        onBegin={primary?.run}
        pill={pill}
        details={details}
        extra={
          <>
            {entry.state === "connect" && entry.keyField && (
              <KeyForm entry={entry} busy={busy} onConnect={(key) => void connect(key)} />
            )}
            {id && <Disconnect entry={entry} id={id} busy={busy} onRun={onRun} />}
          </>
        }
      />
    </div>
  );
}

/** The Connections tab's catalog grid (IntegrationsHubCard draws it above the hub's linked accounts). */
export function ConnectionsPanel({ refreshSignal = 0 }: { refreshSignal?: number }) {
  const store = useStore();
  const ownerId = useId();
  const teams = useSettingsState().accounts?.teams ?? null;
  const team = teams?.options.find((option) => option.active) ?? null;
  const [state, setState] = useState<ConnectionsState | null>(null);
  const [busy, setBusy] = useState(false);
  const [owner, setOwner] = useState<"me" | "team">("me");
  const pollUntil = useRef(0);
  const showUpcoming = useRowState(UPCOMING_KEY).value === true;

  const refresh = useCallback(async () => {
    setState(await store.runConnections({ action: "refresh" }));
  }, [store]);

  // Read again on open, when the window or tab comes back (the sign-in happened in the browser),
  // and on the link a sign-in returns to (`<scheme>://settings/connections`).
  useEffect(() => {
    void refresh();
    const again = () => {
      if (document.visibilityState !== "hidden") void refresh();
    };
    window.addEventListener("focus", again);
    window.addEventListener("hashchange", again);
    document.addEventListener("visibilitychange", again);
    return () => {
      window.removeEventListener("focus", again);
      window.removeEventListener("hashchange", again);
      document.removeEventListener("visibilitychange", again);
    };
  }, [refresh]);
  // The card's Refresh reads this list again too.
  useEffect(() => {
    if (refreshSignal > 0) void refresh();
  }, [refreshSignal, refresh]);

  // After Connect opened a sign-in page, read every few seconds for a minute, until it shows connected.
  const pending = state?.pending ?? null;
  useEffect(() => {
    if (!pending) return;
    const timer = window.setInterval(() => {
      if (Date.now() > pollUntil.current) {
        window.clearInterval(timer);
        return;
      }
      void refresh();
    }, CONNECT_POLL_MS);
    return () => window.clearInterval(timer);
  }, [pending, refresh]);

  const run = useCallback<Run>(
    async (gesture) => {
      setBusy(true);
      try {
        if (gesture.action === "connect" || gesture.action === "reconnect") {
          pollUntil.current = Date.now() + CONNECT_POLL_FOR_MS;
        }
        setState(await store.runConnections(gesture));
      } finally {
        setBusy(false);
      }
    },
    [store],
  );

  const catalog = state?.catalog ?? null;
  const ready = catalog?.ok === true && catalog.available ? catalog : null;
  // Slack and Google say "Not set up" until cmux's client for each is registered; they list only
  // with the Labs toggle on, or once connected.
  const entries = ready
    ? ready.entries
        .filter((entry) => showUpcoming || !entry.upcoming || entry.connectionId)
        .sort((a, b) => a.rank - b.rank)
    : [];
  const whose: Owner = owner === "team" && team ? { owner: "team", team: team.id } : { owner: "me" };
  return (
    <div className="connections-panel" data-connections="">
      <AllConnections entries={entries} pending={pending} busy={busy} onRun={run} />
      <section className="group" data-connections-group="header">
        <div className="row-help">{t("settingsWindow.connections.help")}</div>
        {team && (
          <div className="accounts-header">
            <label className="connections-owner" htmlFor={ownerId}>
              <span className="row-help">{t("settingsWindow.connections.owner")}</span>
              <select
                id={ownerId}
                className={SELECT_CLASS}
                value={owner}
                data-connections-owner=""
                onChange={(event) => setOwner(event.target.value === "team" ? "team" : "me")}
              >
                <option value="me">{t("settingsWindow.connections.owner.me")}</option>
                <option value="team">{team.name}</option>
              </select>
            </label>
          </div>
        )}
        {!state && (
          <div className="row-help" data-connections-checking="">
            {t("settingsWindow.connections.checking")}
          </div>
        )}
        {state?.problem === "unavailable" && (
          <div className="row-error" data-connections-problem="unavailable">
            {t("settingsWindow.connections.problem.unavailable")}
          </div>
        )}
        {catalog?.ok === false && (
          <div className="row-error selectable" role="alert" data-connections-problem={catalog.error.code}>
            {catalog.error.message || t("settingsWindow.connections.problem.failed")}
          </div>
        )}
        {state?.problem === "failed" && !catalog && (
          <div className="row-error" data-connections-problem="failed">
            {t("settingsWindow.connections.problem.failed")}
          </div>
        )}
        {catalog?.ok === true && !catalog.available && (
          <div className="row-help" data-connections-not-here="">
            {catalog.message ?? t("settingsWindow.connections.notHere")}
          </div>
        )}
        {state?.error && (
          <div className="row-error hub-note selectable" role="alert" data-connections-error={state.error.code}>
            {state.error.message || t("settingsWindow.connections.error.notFinished")}
          </div>
        )}
      </section>
      {entries.length > 0 && (
        <section className="group" data-connections-group="catalog">
          <div className="connections-grid">
            {entries.map((entry) => (
              <Tile
                key={entry.name}
                entry={entry}
                busy={busy}
                pending={pending === entry.name}
                owner={whose}
                onRun={run}
              />
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
