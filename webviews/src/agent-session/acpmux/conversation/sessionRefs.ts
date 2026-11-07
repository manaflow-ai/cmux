// Agent session references in a reply: an agent link (`https://cmux.com/deeplink/agent?...`, the
// footer every PR carries, or the native `cmux://agent/<harness>/<session>`) and a `HOST/NAME`
// session name (`gcp-agent-lane-1/opus-session-info`), as an agent writes them in inline code.
// Leo, 2026-11-03: "these links aren't clickable... links like this be able to either open or go
// to these sessions inside a workspace if it's yours. only if it's yours/shared with you".
//
// A reference is found once per code span when its block renders (Markdown.tsx renderInline,
// memoized with the block), and resolved through acpmux (`_acpmux/resolve`, hub/locate.rs) at most
// once per reference, lazily: on hover, focus or click for a link, on idle for a name. The daemon
// resolves only sessions it lists, its own and its peers', which are the reader's own or shared
// with them; a reference it cannot resolve is someone else's (a link opens its web page) or no
// session at all (a name stays plain code).

import { appHref, safeHref } from "../replyHref";

export type SessionRefTarget = {
  /// The session's id as the session list names it (what `chat.offer.open` with `sender` takes).
  sessionId: string;
  name?: string;
  host?: string;
};

export type AgentRef =
  /// An agent link: `href` is what a click opens when the session is not the reader's; `query` what
  /// `_acpmux/resolve` is asked (undefined: a link acpmux cannot resolve).
  | { kind: "link"; href: string; query?: string }
  /// A `HOST/NAME` that may name a session; it is one only if acpmux resolves it.
  | { kind: "name"; query: string };

/// What ends a URL (agent_link.rs `END`): a code span holds exactly the URL.
const WEB_LINK =
  /^https:\/\/(?:www\.)?cmux\.com(?:\/[a-z]{2}(?:-[A-Z]{2})?)?\/deeplink\/agent\/?(?:\?([^\s)>\]"'`]*))?$/;
/// The native agent link, which acpmux reads whole.
const NATIVE_LINK = /^cmux(?:-[a-z0-9-]+)?:\/\/agent\/[^\s)>\]"'`]+$/;
/// `HOST/NAME`: a machine name and a session name or id (session_name.rs's charset, `:` for an id).
const NAME_REF = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\/[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
/// A file name's extension (`src/app.ts`), which no session name written as a reference carries.
const FILE_EXT = /\.[A-Za-z][A-Za-z0-9]{0,11}$/;
/// A harness's own session id, which a link without a harness is resolved by (acpmux matches a
/// bare id against `agentSessionId`).
const SESSION_ID = /^(?!\.+$)[A-Za-z0-9._:-]{1,256}$/;
/// The opaque id of a public link (`?id=aid-...`), which acpmux reads only where it holds the key
/// (opaque_agent_id.rs); elsewhere it resolves nothing and the link opens its web page.
const OPAQUE_ID = /^aid-[0-9a-f]{20}$/;

/// The agent reference `text` (a code span's content) is, or undefined.
export function agentRef(text: string): AgentRef | undefined {
  const value = text.trim();
  if (value.length > 2048) return undefined;
  const web = WEB_LINK.exec(value);
  if (web) {
    const href = safeHref(value);
    if (!href) return undefined;
    const params = new URLSearchParams((web[1] ?? "").replace(/&amp;/g, "&"));
    const harness = params.get("harness");
    const session = params.get("session");
    // A link with its harness is acpmux's to read whole (agent_link.rs); one that names only the
    // session (`?host=&session=`, as lanes print them) is resolved by the session's id. An opaque
    // `?id=` link goes to acpmux whole too.
    const id = params.getAll("id");
    const opaque = id.length === 1 && OPAQUE_ID.test(id[0] ?? "");
    const query = (harness && session) || opaque ? value : session && SESSION_ID.test(session) ? session : undefined;
    return { kind: "link", href, ...(query && { query }) };
  }
  if (NATIVE_LINK.test(value)) {
    const href = appHref(value);
    return href ? { kind: "link", href, query: value } : undefined;
  }
  if (!NAME_REF.test(value)) return undefined;
  const [host, name] = value.split("/") as [string, string];
  // A fraction or a date (`3/4`, `10/31`), and a file (`src/app.ts`), name no session.
  if (/^\d+$/.test(host) && /^\d+$/.test(name)) return undefined;
  if (FILE_EXT.test(name)) return undefined;
  return { kind: "name", query: value };
}

/// The session `_acpmux/resolve`'s reply names (its first match), or null.
export function resolvedTarget(reply: unknown): SessionRefTarget | null {
  const session = (reply as { session?: unknown } | null)?.session as Record<string, unknown> | null | undefined;
  const id = session?.sessionId;
  if (typeof id !== "string" || !id) return null;
  const str = (value: unknown) => (typeof value === "string" && value ? value : undefined);
  const name = str(session?.name);
  const host = str(session?.host);
  return { sessionId: id, ...(name && { name }), ...(host && { host }) };
}

type Resolver = (query: string) => Promise<unknown>;

/// How many answers are kept; the oldest go first.
const MAX_KNOWN = 500;
const known = new Map<string, SessionRefTarget | null>();
const pending = new Map<string, Promise<SessionRefTarget | null>>();
const listeners = new Set<() => void>();
let resolver: Resolver | undefined;

/// Sets how a reference is resolved (App.tsx: `_acpmux/resolve` through the page's client).
/// Without one nothing resolves, and links open their web page.
export function setSessionRefResolver(next: Resolver | undefined): void {
  resolver = next;
}

/// Whether references can resolve here at all.
export function sessionRefsResolve(): boolean {
  return resolver !== undefined;
}

/// What `query` resolved to: its session, null for none, undefined before it was asked.
export function knownSessionRef(query: string): SessionRefTarget | null | undefined {
  return known.get(query);
}

/// Resolves `query` once; later calls share the answer. A failed ask (not found, refused, no
/// daemon) is an answer: no session.
export function resolveSessionRef(query: string): Promise<SessionRefTarget | null> {
  if (known.has(query)) return Promise.resolve(known.get(query)!);
  const inFlight = pending.get(query);
  if (inFlight) return inFlight;
  if (!resolver) return Promise.resolve(null);
  const ask = resolver(query)
    .then(resolvedTarget, () => null)
    .then((target) => {
      pending.delete(query);
      if (known.size >= MAX_KNOWN) known.delete(known.keys().next().value!);
      known.set(query, target);
      for (const listener of listeners) listener();
      return target;
    });
  pending.set(query, ask);
  return ask;
}

export function subscribeSessionRefs(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Forgets every answer (tests).
export function resetSessionRefs(): void {
  known.clear();
  pending.clear();
}

/// How long a name waits for an idle moment before it is resolved anyway.
export const NAME_RESOLVE_IDLE_MS = 1500;

/// Runs `run` once the page is idle; returns its cancel.
export function whenIdle(run: () => void): () => void {
  const scope = globalThis as {
    requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number;
    cancelIdleCallback?: (handle: number) => void;
  };
  if (scope.requestIdleCallback && scope.cancelIdleCallback) {
    const handle = scope.requestIdleCallback(run, { timeout: NAME_RESOLVE_IDLE_MS });
    return () => scope.cancelIdleCallback!(handle);
  }
  const timer = setTimeout(run, 50);
  return () => clearTimeout(timer);
}
