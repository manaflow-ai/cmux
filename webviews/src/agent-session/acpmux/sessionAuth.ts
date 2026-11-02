import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { translate, type Translate } from "./i18n";
/** The session/selected-route auth verdict from acpmux. Unknown is never a refusal. */
export type SessionAuthState =
  | "ready"
  | "signedOut"
  | "expired"
  | "routeAuthNeeded"
  | "routeUnreachable"
  | "peerUnreachable"
  | "unknown";
export type SessionAuthSource = "peerLink" | "routeProbe" | "turn" | "authCheck" | "none";
export type SessionAuth = {
  state: SessionAuthState;
  source: SessionAuthSource;
  evidenceAt: number | null;
  detail?: string;
  harness?: string;
  host?: string | null;
  routeId?: string | null;
  fromSessionId?: string | null;
  login?: { kind: "terminal" | "route"; command?: string; host?: string | null; routeId?: string | null };
};
export const UNKNOWN_AUTH: SessionAuth = { state: "unknown", source: "none", evidenceAt: null };
const states = new Set<SessionAuthState>([
  "ready",
  "signedOut",
  "expired",
  "routeAuthNeeded",
  "routeUnreachable",
  "peerUnreachable",
  "unknown",
]);
const sources = new Set<SessionAuthSource>(["peerLink", "routeProbe", "turn", "authCheck", "none"]);
export function readSessionAuth(reply: unknown): SessionAuth {
  if (!reply || typeof reply !== "object") return UNKNOWN_AUTH;
  const row = reply as Record<string, unknown>;
  if (!states.has(row.state as SessionAuthState) || !sources.has(row.source as SessionAuthSource)) return UNKNOWN_AUTH;
  if (
    (row.state === "signedOut" || row.state === "expired" || row.state === "routeAuthNeeded") &&
    row.source === "none"
  )
    return UNKNOWN_AUTH;
  const login = row.login && typeof row.login === "object" ? (row.login as Record<string, unknown>) : undefined;
  // A malformed remote host must never be dropped and interpreted as this computer.
  if (
    (row.host !== undefined && row.host !== null && typeof row.host !== "string") ||
    (login?.host !== undefined && login.host !== null && typeof login.host !== "string")
  )
    return UNKNOWN_AUTH;

  return {
    state: row.state as SessionAuthState,
    source: row.source as SessionAuthSource,
    evidenceAt: typeof row.evidenceAt === "number" && Number.isFinite(row.evidenceAt) ? row.evidenceAt : null,
    ...(typeof row.detail === "string" ? { detail: row.detail } : {}),
    ...(typeof row.harness === "string" ? { harness: row.harness } : {}),
    ...(typeof row.host === "string" || row.host === null ? { host: row.host as string | null } : {}),
    ...(typeof row.routeId === "string" || row.routeId === null ? { routeId: row.routeId as string | null } : {}),
    ...(typeof row.fromSessionId === "string" || row.fromSessionId === null
      ? { fromSessionId: row.fromSessionId as string | null }
      : {}),
    ...(login && (login.kind === "terminal" || login.kind === "route")
      ? {
          login: {
            kind: login.kind,
            ...(typeof login.command === "string" ? { command: login.command } : {}),
            ...(typeof login.host === "string" || login.host === null ? { host: login.host as string | null } : {}),
            ...(typeof login.routeId === "string" || login.routeId === null
              ? { routeId: login.routeId as string | null }
              : {}),
          },
        }
      : {}),
  };
}
export function isAuthPreflightPending(
  routeChanging: string | undefined,
  routeAuthPending: boolean,
  sessionId: string | undefined,
  authPending: boolean,
): boolean {
  return authPending || (routeAuthPending && routeChanging !== undefined && routeChanging === sessionId);
}

export function useRouteAuthSwitch(apply: (sessionId: string, routeId: string) => Promise<void>, onEpoch: () => void) {
  const [routeChanging, setRouteChanging] = useState<string>();
  const [routeAuthPending, setRouteAuthPending] = useState(false);
  const [routeAuthStarted, setRouteAuthStarted] = useState(false);
  const serial = useRef(0);
  const settleRoute = useCallback(
    (sessionId: string | undefined, pending: boolean) => {
      if (!(routeAuthPending && routeAuthStarted && routeChanging === sessionId && !pending)) return;
      setRouteAuthPending(false);
      setRouteAuthStarted(false);
      setRouteChanging(undefined);
    },
    [routeChanging, routeAuthPending, routeAuthStarted],
  );
  const switchRoute = useCallback(
    async (sessionId: string, routeId: string) => {
      const request = ++serial.current;
      setRouteChanging(sessionId);
      setRouteAuthPending(true);
      setRouteAuthStarted(false);
      try {
        await apply(sessionId, routeId);
        if (request !== serial.current) return;
        onEpoch();
        setRouteAuthStarted(true);
      } catch (error) {
        if (request === serial.current) {
          setRouteAuthPending(false);
          setRouteChanging(undefined);
        }
        throw error;
      }
    },
    [apply, onEpoch],
  );
  return { routeChanging, routeAuthPending, routeAuthStarted, settleRoute, switchRoute };
}

export function authBlocksSend(auth: SessionAuth | undefined): boolean {
  return auth?.state === "signedOut" || auth?.state === "expired" || auth?.state === "routeAuthNeeded";
}
export function authLoginText(auth: SessionAuth | undefined, t: Translate = translate): string {
  return t(
    auth?.state === "expired" ||
      auth?.state === "routeAuthNeeded" ||
      (auth?.state === "signedOut" && auth.source === "turn")
      ? "turn.signInAgain"
      : "harness.logIn",
  );
}
export function authText(auth: SessionAuth | undefined, t: Translate = translate): string | undefined {
  if (!auth) return undefined;
  const harness = auth.harness ?? t("picker.model");
  const label =
    auth.state === "signedOut"
      ? t("harness.signedOut", { agent: harness })
      : auth.state === "expired"
        ? t("turn.authExpired")
        : auth.state === "routeAuthNeeded"
          ? `${t("picker.account")} · ${authLoginText(auth, t)}`
          : auth.state === "routeUnreachable"
            ? t("turn.failure.unreachableVia", { harness, via: auth.routeId ?? t("picker.account") })
            : auth.state === "peerUnreachable"
              ? t("turn.failure.unreachableVia", { harness, via: auth.host ?? t("environment.host") })
              : undefined;
  if (!label) return undefined;
  const host = auth.login?.host ?? auth.host;
  const recovery =
    auth.login?.kind === "terminal" && host && auth.login.command
      ? `${t("picker.unavailable")} · ${host}: ${auth.login.command}`
      : auth.login?.kind === "route"
        ? `${t("picker.accountHint")} · ${auth.login.routeId ?? auth.routeId ?? ""}`
        : undefined;
  return [label, auth.detail, recovery].filter(Boolean).join(" · ");
}

export function authChipText(auth: SessionAuth | undefined, t: Translate = translate): string | undefined {
  return authBlocksSend(auth)
    ? authLoginText(auth, t)
    : auth?.state === "routeUnreachable" || auth?.state === "peerUnreachable"
      ? t("picker.unavailable")
      : undefined;
}

export const canSessionLogin = (auth: SessionAuth | undefined): boolean =>
  authBlocksSend(auth) &&
  auth?.login?.kind === "terminal" &&
  Boolean(auth.login.command) &&
  (auth.login.host === undefined || auth.login.host === null) &&
  auth.host === null;

export async function sessionLogin(
  auth: SessionAuth,
  open: (params: Record<string, unknown>) => Promise<unknown>,
  cwd?: string,
): Promise<string | undefined> {
  const command = auth.login?.command;
  if (!command || !canSessionLogin(auth)) return authText(auth);
  await open({ kind: "terminal", text: command, ...(cwd ? { cwd } : {}), run: true });
}

/// What `/login` runs (Lawrence, via Leo: "in gui, having /resume would be nice, maybe /login as
/// well"): acpmux's own sign-in for a chat it found signed out (its command keeps the route's
/// account home); else, for a chat acpmux says is on this Mac (`host: null`, never a missing or
/// unknown host) with no route, the harness's declared login (`catalog[].auth.login`), so a
/// signed-in chat can sign in again or switch accounts. A route may name its own account home and
/// another host signs in there, so neither gets the default login.
export function slashLogin(
  auth: SessionAuth | undefined,
  declared: string | undefined,
): { kind: "session" } | { kind: "terminal"; command: string } | undefined {
  if (canSessionLogin(auth)) return { kind: "session" };
  const command = declared?.trim();
  if (!command || !auth || auth.host !== null || auth.routeId || auth.login?.kind === "route" || auth.login?.host)
    return undefined;
  return { kind: "terminal", command };
}

export type SessionAuthQuery = { sessionId: string } | { target: { harness: string; host?: string; routeId?: string } };
export type ReadSessionAuth = (query: SessionAuthQuery, refresh?: boolean) => Promise<unknown>;

export function useSessionAuth(
  query: SessionAuthQuery | undefined,
  read: ReadSessionAuth | undefined,
  epoch: string | number = 0,
  refreshEpoch = 0,
  observationEpoch = 0,
) {
  const key = JSON.stringify(query);
  const selected = useMemo(() => (key ? (JSON.parse(key) as SessionAuthQuery) : undefined), [key]);
  const [refresh, setRefresh] = useState(0);
  const selection = useMemo(() => ({ selected, read, epoch }), [selected, read, epoch]);
  const version = JSON.stringify([refresh, refreshEpoch, observationEpoch]);
  const checked = useRef<{ selection: typeof selection | undefined; refresh: number; refreshEpoch: number }>({
    selection: undefined,
    refresh: 0,
    refreshEpoch,
  });
  const [result, setResult] = useState<{ selection: typeof selection; auth: SessionAuth }>();
  useEffect(() => {
    if (!read || !selected) return;
    let live = true;
    const selectionChanged = checked.current.selection !== selection;
    const probe =
      selectionChanged || checked.current.refresh !== refresh || checked.current.refreshEpoch !== refreshEpoch;
    checked.current = { selection, refresh, refreshEpoch };
    void read(selected, probe).then(
      (reply) => {
        if (!live) return;
        const auth = readSessionAuth(reply);
        const scopeMismatch =
          ("sessionId" in selected && auth.fromSessionId && auth.fromSessionId !== selected.sessionId) ||
          ("target" in selected &&
            ((auth.harness !== undefined && auth.harness !== selected.target.harness) ||
              (auth.host ?? undefined) !== selected.target.host ||
              (selected.target.routeId !== undefined && auth.routeId !== selected.target.routeId)));
        if (scopeMismatch) {
          setResult((previous) => (previous?.selection === selection ? previous : { selection, auth: UNKNOWN_AUTH }));
          return;
        }
        setResult({ selection, auth });
      },
      () => {
        if (live)
          setResult((previous) => (previous?.selection === selection ? previous : { selection, auth: UNKNOWN_AUTH }));
      },
    );
    return () => {
      live = false;
    };
  }, [read, selected, selection, refresh, refreshEpoch, version]);
  const recheck = useCallback(() => setRefresh((n) => n + 1), []);
  return {
    auth: result?.selection === selection ? result.auth : UNKNOWN_AUTH,
    pending: Boolean(read && selected) && result?.selection !== selection,
    recheck,
  };
}
