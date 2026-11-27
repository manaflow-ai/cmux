import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { agentDisplayName } from "./agents";
import { translate, type Translate } from "./i18n";
import { providerName } from "./modelVariants";
import { afterNextPaint } from "./afterNextPaint";
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
/** Whose credential refused the chat: the agent's own login, a provider's API key, or the cmux account. */
export type SessionAuthCredential = "login" | "apiKey" | "cmux";
export type SessionAuth = {
  state: SessionAuthState;
  source: SessionAuthSource;
  evidenceAt: number | null;
  detail?: string;
  harness?: string;
  host?: string | null;
  routeId?: string | null;
  fromSessionId?: string | null;
  credential?: SessionAuthCredential;
  /** The provider id that issued a refused API key ("opencode-go"). */
  provider?: string;
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
    ...(row.credential === "login" || row.credential === "apiKey" || row.credential === "cmux"
      ? { credential: row.credential }
      : {}),
    ...(typeof row.provider === "string" && row.provider ? { provider: row.provider } : {}),
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
/// Who refused the chat, so the words name that party and the button offers the one fix that works
/// (user, Nov 19: "hard to tell if cmux is signed out or the model provider is signed out"): the
/// person's cmux account, a provider's API key (signing in again never renews one), a route by its
/// name, else the agent's own login.
export type AuthParty =
  | { kind: "cmux" }
  | { kind: "apiKey"; provider: string }
  | { kind: "route"; route?: string }
  | { kind: "login"; agent?: string };

/// An answer that names no harness (or no route) keeps the plain words it always had: a name
/// there would be a guess.
export function authParty(auth: SessionAuth, t: Translate = translate): AuthParty {
  const agent = auth.harness ? agentDisplayName(auth.harness) : undefined;
  if (auth.credential === "cmux") return { kind: "cmux" };
  if (auth.credential === "apiKey")
    return { kind: "apiKey", provider: auth.provider ? providerName(auth.provider) : (agent ?? t("picker.model")) };
  if (auth.state === "routeAuthNeeded") {
    const route = auth.login?.routeId ?? auth.routeId ?? undefined;
    return route ? { kind: "route", route } : { kind: "route" };
  }
  return agent ? { kind: "login", agent } : { kind: "login" };
}

/// The button (and the model chip's word) that fixes the refusal: "Replace key", "Sign in to cmux",
/// "Sign in to Claude Code". It says what it does, the same wherever it shows.
export function authLoginText(auth: SessionAuth | undefined, t: Translate = translate): string {
  if (!auth) return t("harness.logIn");
  const party = authParty(auth, t);
  switch (party.kind) {
    case "cmux":
      return t("auth.fix.signInCmux");
    case "apiKey":
      return t("auth.fix.replaceKey");
    case "route":
      return party.route ? t("auth.fix.signInTo", { name: party.route }) : t("turn.signInAgain");
    case "login":
      if (party.agent) return t("auth.fix.signInTo", { name: party.agent });
      return auth.state === "expired" || auth.source === "turn" ? t("turn.signInAgain") : t("harness.logIn");
  }
}

/// One plain sentence that names who refused the chat and what fixes it. Never the daemon's
/// `detail` (its diagnostic, with the agent's raw error), and never two messages joined.
export function authText(auth: SessionAuth | undefined, t: Translate = translate): string | undefined {
  if (!auth) return undefined;
  const harness = auth.harness ? agentDisplayName(auth.harness) : t("picker.model");
  if (auth.state === "routeUnreachable")
    return t("turn.failure.unreachableVia", { harness, via: auth.routeId ?? t("picker.account") });
  if (auth.state === "peerUnreachable")
    return t("turn.failure.unreachableVia", { harness, via: auth.host ?? t("environment.host") });
  if (!authBlocksSend(auth)) return undefined;
  const party = authParty(auth, t);
  const expired = auth.state === "expired";
  const label =
    party.kind === "cmux"
      ? t("auth.cmux.signedOut")
      : party.kind === "apiKey"
        ? t(expired ? "auth.key.expired" : "auth.key.refused", { provider: party.provider })
        : party.kind === "route"
          ? party.route
            ? t("auth.route.signedOut", { name: party.route })
            : t("turn.authExpired")
          : party.agent
            ? t(expired ? "auth.login.expired" : "auth.login.signedOut", { agent: party.agent })
            : expired
              ? t("turn.authExpired")
              : t("harness.signedOut", { agent: harness });
  // A chat on another machine signs in there: say where and what to run, as its own sentence.
  const host = auth.login?.host ?? auth.host;
  if (auth.login?.kind === "terminal" && host && auth.login.command && party.kind !== "cmux")
    return `${label} ${t("auth.runOnHost", { host, command: auth.login.command })}`;
  return label;
}

/// The model chip's word before the model. A chat whose machine is down gets none: the link is the
/// machine's, not the model's, and the quiet row's machine link says it in the sidebar's words
/// (MachineLinkStatus.tsx); "Unavailable" there read as the model being unavailable. The chip's
/// label (authText) still names the cause.
export function authChipText(auth: SessionAuth | undefined, t: Translate = translate): string | undefined {
  return authBlocksSend(auth)
    ? authLoginText(auth, t)
    : auth?.state === "routeUnreachable"
      ? t("picker.unavailable")
      : undefined;
}

export const canSessionLogin = (auth: SessionAuth | undefined): boolean =>
  (authBlocksSend(auth) && auth?.credential === "cmux") ||
  (authBlocksSend(auth) &&
    auth?.login?.kind === "terminal" &&
    Boolean(auth.login.command) &&
    (auth.login.host === undefined || auth.login.host === null) &&
    auth.host === null);

/// The fix the button runs, one path for every place it shows (the composer menu, the quick menu,
/// `/login`): the app's own cmux sign-in for the cmux account, else the agent's login command in a
/// terminal (for an API key, the agent's key entry, `opencode auth login`).
export async function sessionLogin(
  auth: SessionAuth,
  open: (params: Record<string, unknown>) => Promise<unknown>,
  cwd?: string,
  signInCmux?: () => Promise<unknown>,
): Promise<string | undefined> {
  if (auth.credential === "cmux" && authBlocksSend(auth)) {
    if (!signInCmux) return authText(auth);
    await signInCmux();
    return;
  }
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

export type SessionAuthQuery =
  | { sessionId: string }
  | { target: { harness: string; host?: string; routeId?: string; cwd?: string } };
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
    // A new selection reads its sign-in after the frame that draws it: a reply that came first (a
    // local daemon answers at once) would render the pane again before that frame paints.
    const ask = () =>
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
    const cancel = selectionChanged ? afterNextPaint(ask) : (ask(), undefined);
    return () => {
      live = false;
      cancel?.();
    };
  }, [read, selected, selection, refresh, refreshEpoch, version]);
  const recheck = useCallback(() => setRefresh((n) => n + 1), []);
  return {
    auth: result?.selection === selection ? result.auth : UNKNOWN_AUTH,
    pending: Boolean(read && selected) && result?.selection !== selection,
    recheck,
  };
}
