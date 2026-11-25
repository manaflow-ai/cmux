// Settings > Integrations > Connections, on top: All connections, one compact row per connection the
// person has, wherever it is managed: their cmux account, GitHub, each model account (a harness login,
// a ChatGPT or Claude sign-in, an API key), and every app connected over MCP. Each row is its title,
// a status pill (shared/connect/ConnectPill.tsx) and one action. Account and model rows only reflect
// the host's state and open the section that manages them (Manage); an app row's action is the one
// its tile below offers (Reconnect, Turn On), or Manage, which scrolls to that tile.
//
// Leo, 2026-11-25: "btw actually on the whole claude setup situation what about other ones? chatgpt?
// are there deeper ergo things we can do wrt that? and other apps and whatnot? and also spruce up the
// signed in to github page situation? maybe our auth too?"
import { Button } from "../../../ui/Button";
import { ConnectPill } from "../../shared/connect/ConnectPill";
import { focusRoute } from "../../../ui/focusRoute";
import { expiryStatus, type ConnectStatus } from "../../shared/connect/connectStatus";
import { useConnectStrings } from "../../shared/connect/strings";
import { useSignInStrings } from "../../shared/signIn/strings";
import { useSettingsRouter, useSettingsState } from "../context";
import type { AccountsState, ConnectionEntry, ConnectionsRun } from "../ops";
import { sectionHref } from "../router";

type Kind = "account" | "model" | "app";
type Gesture = Exclude<ConnectionsRun, { action: "refresh" }>;

/** One row: what it is, its pill, and its one action (null while it waits on a sign-in). */
export type AllConnectionsRow = {
  id: string;
  kind: Kind;
  /** The row's name; a sign-in family's rows (GitHub, ChatGPT, Claude) name the family instead. */
  title: string;
  family?: "github" | "codex" | "claude";
  detail: string | null;
  status: ConnectStatus;
  /** The host's own words for the state; null shows the pill's. */
  label: string | null;
  action: { name: "manage" | "reconnect" | "enable"; to?: "accounts" | "models"; entry?: string; run?: Gesture } | null;
};

/** A tile's pill: waiting while its sign-in page is open, else the catalog's state, with a connected
 * entry whose sign-in lapses soon (or lapsed) showing that instead. */
export function tileStatus(entry: ConnectionEntry, pending: boolean, now = Date.now()): ConnectStatus {
  if (pending) return "connecting";
  if (entry.state === "connected") return expiryStatus(entry.expiresAt, now) ?? "connected";
  return STATUS[entry.state];
}

const STATUS: Record<ConnectionEntry["state"], ConnectStatus> = {
  connected: "connected",
  reconnect: "reauth",
  enable: "attention",
  connect: "connect",
  unavailable: "unavailable",
};

const ACCOUNT_STATUS: Record<"success" | "attention" | "neutral" | "quiet", ConnectStatus> = {
  success: "connected",
  attention: "attention",
  neutral: "connect",
  quiet: "connect",
};

/** Every connection the person has, in one order: cmux, GitHub, model accounts, then apps by rank. */
export function allConnectionRows(
  accounts: AccountsState | null | undefined,
  entries: ConnectionEntry[],
  pending: string | null,
  now = Date.now(),
): AllConnectionsRow[] {
  const rows: AllConnectionsRow[] = [];
  const manage = (to: "accounts" | "models") => ({ name: "manage" as const, to });
  if (accounts) {
    rows.push({
      id: "cmux",
      kind: "account",
      title: accounts.cmux.title,
      detail: accounts.cmux.detail,
      status: ACCOUNT_STATUS[accounts.cmux.statusKind],
      label: accounts.cmux.status || null,
      action: manage("accounts"),
    });
    // GitHub is one row: the integration's linked accounts and the GitHub sign-ins, both managed in
    // Accounts, so the person never sees two rows called GitHub.
    const githubSignIns = (accounts.signInAccounts ?? []).filter((row) => row.family === "github");
    if (accounts.github || githubSignIns.length > 0) {
      const linked = accounts.github?.connections ?? [];
      const names = [...githubSignIns.map((row) => row.name), ...linked.map((connection) => connection.account)];
      const connected = linked.length > 0 || githubSignIns.some((row) => row.signedIn);
      rows.push({
        id: "github",
        kind: "account",
        title: "",
        family: "github",
        detail: [...new Set(names.filter(Boolean))].join(", ") || null,
        status: connected ? "connected" : githubSignIns.length > 0 ? "reauth" : "connect",
        label: null,
        action: manage("accounts"),
      });
    }
    for (const row of accounts.signInAccounts ?? []) {
      if (row.family === "github") continue;
      rows.push({
        id: `signin:${row.family}:${row.id}`,
        kind: "model",
        title: "",
        family: row.family,
        detail: [row.name, row.email && row.email !== row.name ? row.email : null].filter(Boolean).join(" · ") || null,
        status: row.signedIn ? "connected" : "reauth",
        label: null,
        action: manage("models"),
      });
    }
    for (const group of accounts.groups) {
      for (const row of group.rows) {
        // A provider the host found nothing for is not a connection yet (Settings > Accounts offers it).
        if (row.statusKind === "quiet") continue;
        rows.push({
          id: `model:${group.id}:${row.provider}`,
          kind: "model",
          title: row.name,
          detail: row.detail,
          status: ACCOUNT_STATUS[row.statusKind],
          label: row.status || null,
          action: manage("accounts"),
        });
      }
    }
  }
  for (const entry of entries) {
    const id = entry.connectionId;
    if (!id && pending !== entry.name) continue;
    const status = tileStatus(entry, pending === entry.name, now);
    const action: AllConnectionsRow["action"] =
      status === "connecting"
        ? null
        : id && (entry.state === "reconnect" || status === "expiring" || status === "reauth")
          ? { name: "reconnect", run: { action: "reconnect", id } }
          : id && entry.state === "enable"
            ? { name: "enable", run: { action: "enable", id } }
            : { name: "manage", entry: entry.name };
    rows.push({
      id: `app:${entry.name}`,
      kind: "app",
      title: entry.title,
      detail: entry.ownerLabel,
      status,
      label: status === "connected" || status === "attention" ? entry.statusLabel : null,
      action,
    });
  }
  return rows;
}

export function AllConnections({
  entries,
  pending,
  busy,
  onRun,
}: {
  entries: ConnectionEntry[];
  pending: string | null;
  busy: boolean;
  onRun: (run: Gesture) => Promise<void>;
}) {
  const strings = useConnectStrings();
  const signIn = useSignInStrings();
  const router = useSettingsRouter();
  const accounts = useSettingsState().accounts;
  const rows = allConnectionRows(accounts, entries, pending);
  if (rows.length === 0) return null;
  const go = (action: NonNullable<AllConnectionsRow["action"]>) => {
    if (action.run) return void onRun(action.run);
    if (action.to) return void router.history.push(sectionHref(action.to));
    // An app is managed in its tile right below: bring it into view and onto its first control.
    const tile = document.querySelector<HTMLElement>(`[data-connections-entry="${action.entry}"]`);
    tile?.scrollIntoView({ block: "nearest" });
    focusRoute(tile?.querySelector<HTMLElement>("button, input"), "person", "All connections Manage: the app's tile");
  };
  const label = (name: "manage" | "reconnect" | "enable") => strings.t(`connect.action.${name}`);
  return (
    <section className="group all-connections" data-all-connections="" aria-labelledby="all-connections-title">
      <div className="row-title" id="all-connections-title">
        {strings.t("connect.all.title")}
      </div>
      <div className="row-help">{strings.t("connect.all.help")}</div>
      <ul className="all-connections-list">
        {rows.map((row) => (
          <li
            key={row.id}
            className="all-connections-row"
            data-all-connections-row={row.id}
            data-all-connections-kind={row.kind}
          >
            <span className="all-connections-text">
              <span className="all-connections-title" id={`all-connections-${row.id.replace(/[^\w-]/g, "-")}`}>
                {row.family ? signIn.t(`signIn.group.${row.family}`) : row.title}
              </span>
              <span className="row-help all-connections-detail">
                {[strings.t(`connect.all.kind.${row.kind}`), row.detail].filter(Boolean).join(" · ")}
              </span>
            </span>
            <ConnectPill status={row.status} label={row.label} dataPrefix="all-connections" />
            {row.action && (
              <Button
                variant={row.action.name === "manage" ? "ghost" : "solid"}
                className="button"
                disabled={busy && !!row.action.run}
                data-all-connections-action={row.action.name}
                aria-describedby={`all-connections-${row.id.replace(/[^\w-]/g, "-")}`}
                onClick={() => go(row.action!)}
              >
                {label(row.action.name)}
              </Button>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
