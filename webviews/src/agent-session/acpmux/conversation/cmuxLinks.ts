// What a cmux link names (plans/cmux-next/links.json, CmuxNextActions `DeepLink.parse`): the parse a
// pasted link's chip draws from (chips/CmuxLinkChip.tsx). Leo, 2026-11-08, of a workspace link he
// pasted: "it should be able to render in the box that it is an actual chat that is there, like
// with the title and whatever, and, like, to be potentially hoverable as well, instead of just
// being, like, you know, here's the raw URL". The app parses the link again when it opens it
// (`link.open`); this only reads what to draw, so a link it does not read stays the plain link.
//
// Forms, in any build's scheme (`cmux`, `cmux-nightly`, `cmux-dev-<tag>`):
// - `<scheme>://workspace/ws_<32 hex>`, `pane/pane_<32 hex>`, `tab/tab_<32 hex>`, each with an
//   optional `?machine=machine_<32 hex>` (Copy Link to Workspace, Copy Link to Tab);
// - `<scheme>://session/<id>[#turn-<turn>]`, an acpmux chat and one of its turns;
// - `<scheme>://chief/<8 hex>/session/<id>`, a Chief subagent's chat;
// - `<scheme>://agent/<harness>/<session>?host=&name=&message=`, an outside agent's session
//   (schemas/deeplinks/agent-link.json);
// - `<scheme>://group/grp_<id>[/workspace/ws_<32 hex>]`, a cloud group;
// - `https://cmux.com[/<locale>]/deeplink/agent?harness=&session=&host=&name=` (the same agent
//   link's web page), `?host=&session=` (a session by its id alone) and `?id=aid-…` (an opaque
//   public link, which only acpmux reads).

export type CmuxLinkTarget =
  | { kind: "workspace" | "pane" | "tab"; id: string; machine?: string }
  | { kind: "session"; session: string; turn?: string }
  | { kind: "chief"; home: string; session: string }
  | {
      kind: "agent";
      /// Absent for a web link that names only the session (`?host=&session=`) or an opaque id.
      harness?: string;
      session?: string;
      /// The `?host=` and `?name=` display hints: never used to find the session.
      host?: string;
      name?: string;
      /// An opaque public link's `?id=aid-…`.
      opaque?: string;
      web: boolean;
    }
  | { kind: "group"; id: string; workspace?: string };

const SCHEME = /^cmux(?:-[a-z0-9-]+)?$/;
const HEX32 = "[0-9a-f]{32}";
const RESOURCE: Record<"workspace" | "pane" | "tab", RegExp> = {
  workspace: new RegExp(`^ws_${HEX32}$`),
  pane: new RegExp(`^pane_${HEX32}$`),
  tab: new RegExp(`^tab_${HEX32}$`),
};
const MACHINE = new RegExp(`^machine_${HEX32}$`);
/// A session or turn id (DeepLink.isToken): nothing to escape.
const TOKEN = /^[A-Za-z0-9._-]{1,200}$/;
/// A harness's own session id (DeepLink.isAgentSession).
const AGENT_SESSION = /^(?!\.+$)[A-Za-z0-9._:-]{1,256}$/;
const HARNESS = /^[a-z0-9-]{1,64}$/;
/// A `?host=` or `?name=` hint (DeepLink.isHint): a malformed one is dropped, never the link.
const HINT = /^(?!\.+$)[A-Za-z0-9._:-]{1,64}$/;
const CHIEF_HOME = /^[0-9a-f]{8}$/;
const GROUP = /^grp_[a-z0-9]{20}$/;
const OPAQUE = /^aid-[0-9a-f]{20}$/;
const WEB = /^https:\/\/(?:www\.)?cmux\.com(?:\/[a-z]{2}(?:-[A-Z]{2})?)?\/deeplink\/agent\/?$/;
/// Longer than any link the app writes: a pasted wall of text is never parsed as one.
const MAX_LINK = 2048;

/// The one value of `name` in `query`, when the query carries it once and it fits `pattern`.
function single(query: URLSearchParams, name: string, pattern: RegExp): string | undefined {
  const values = query.getAll(name);
  return values.length === 1 && pattern.test(values[0]!) ? values[0] : undefined;
}

function hints(query: URLSearchParams): { host?: string; name?: string } {
  const host = single(query, "host", HINT);
  const name = single(query, "name", HINT);
  return { ...(host && { host }), ...(name && { name }) };
}

/// What `href` (a cmux app link or a cmux.com agent link) names, or undefined for any other text.
export function cmuxLinkTarget(href: string): CmuxLinkTarget | undefined {
  const text = href.trim();
  if (!text || text.length > MAX_LINK || /\s/.test(text)) return undefined;
  const split = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/.exec(text);
  if (!split) return undefined;
  const [, scheme = "", path = "", rawQuery = "", fragment] = split;
  const query = new URLSearchParams(rawQuery.replace(/&amp;/g, "&"));
  if (scheme === "https") return webTarget(`https://${path}`, query);
  if (!SCHEME.test(scheme)) return undefined;
  const parts = path.split("/");
  const [kind, first, second, third] = parts;
  if ((kind === "workspace" || kind === "pane" || kind === "tab") && parts.length === 2) {
    if (!first || !RESOURCE[kind].test(first) || fragment !== undefined) return undefined;
    const machine = single(query, "machine", MACHINE);
    return { kind, id: first, ...(machine && { machine }) };
  }
  if (kind === "session" && parts.length === 2 && first && TOKEN.test(first)) {
    if (fragment === undefined) return { kind: "session", session: first };
    const turn = fragment.startsWith("turn-") ? fragment.slice("turn-".length) : "";
    return TOKEN.test(turn) ? { kind: "session", session: first, turn } : undefined;
  }
  if (kind === "chief" && parts.length === 4 && second === "session" && first && third) {
    return CHIEF_HOME.test(first) && TOKEN.test(third) ? { kind: "chief", home: first, session: third } : undefined;
  }
  if (kind === "agent" && parts.length === 3 && first && second && fragment === undefined) {
    if (!HARNESS.test(first) || !AGENT_SESSION.test(second)) return undefined;
    return { kind: "agent", harness: first, session: second, ...hints(query), web: false };
  }
  if (kind === "group" && first && GROUP.test(first)) {
    if (parts.length === 2) return { kind: "group", id: first };
    if (parts.length === 4 && second === "workspace" && third && RESOURCE.workspace.test(third))
      return { kind: "group", id: first, workspace: third };
  }
  return undefined;
}

/// A cmux.com agent link: its harness and session, a session alone, or an opaque id.
function webTarget(base: string, query: URLSearchParams): CmuxLinkTarget | undefined {
  if (!WEB.test(base)) return undefined;
  const harness = single(query, "harness", HARNESS);
  const session = single(query, "session", AGENT_SESSION);
  const opaque = single(query, "id", OPAQUE);
  if (harness && session) return { kind: "agent", harness, session, ...hints(query), web: true };
  if (session && !query.has("harness")) return { kind: "agent", session, ...hints(query), web: true };
  if (opaque) return { kind: "agent", opaque, ...hints(query), web: true };
  return undefined;
}

/// Whether `target` names a chat (an acpmux session), as against a place in a window.
export function namesChat(
  target: CmuxLinkTarget,
): target is Extract<CmuxLinkTarget, { kind: "session" | "chief" | "agent" }> {
  return target.kind === "session" || target.kind === "chief" || target.kind === "agent";
}
