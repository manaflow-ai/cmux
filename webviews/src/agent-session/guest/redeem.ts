// Joining a shared chat (design/chat-multiplayer.md 3 and 4.3): the link is
// `/g/<share_id>#<secret>`. The secret never stays in the address bar: the page reads it and
// takes the fragment out of the URL at once. It is kept in this tab's sessionStorage only until
// the redeem succeeds, so a reload before Join still works. Redeem POSTs once, same origin, with an
// `attempt_id` kept in sessionStorage, so a retry after a lost reply is the same attempt and
// spends no second use.
//
// An invite (a person the owner invited by account) is `/i/<share_id>`: no secret at all. The room
// signs the visitor in with their cmux account before it serves the page, and Join POSTs `accept`
// with only the attempt id; the room takes the account and the name from that sign-in.
import { displayName } from "../acpmux/multiplayer/participants";

/** A share or secret id as the daemon makes them: 128-bit, URL-safe. */
const ID = /^[A-Za-z0-9_-]{8,128}$/;

/** `invite`: an account invite (`/i/<id>`), joined by the signed-in account instead of a secret. */
export type GuestLink = { shareId: string; secret?: string; invite?: true };

/** An invitee's role: `view` watches only, `talk` may also send messages (each held for the owner). */
export type GuestRole = "view" | "talk";

/** How a tab joined: by the link's secret (an anonymous guest) or by an invite's accept (the account). */
export type JoinedVia = "link" | "invite";

/** Errors the room answers a redeem with; anything else is `failed`. */
export type RedeemError =
  | "share.expired"
  | "share.revoked"
  | "share.closed"
  | "share.used"
  | "share.kicked"
  | "share.left"
  | "share.host_offline"
  | "share.not_invited"
  | "share.unauthorized"
  | "share.unverified"
  | "failed";
export type RedeemResult = { ok: true; guestId: string; role?: GuestRole } | { ok: false; error: RedeemError };
export type RedeemRequest = { attempt_id: string; secret: string; name: string };
export type Redeem = (shareId: string, request: RedeemRequest) => Promise<RedeemResult>;
export type AcceptRequest = { attempt_id: string };
export type Accept = (shareId: string, request: AcceptRequest) => Promise<RedeemResult>;

const KNOWN: ReadonlySet<string> = new Set([
  "share.expired",
  "share.revoked",
  "share.closed",
  "share.used",
  "share.kicked",
  "share.left",
  "share.host_offline",
  "share.not_invited",
  "share.unauthorized",
  "share.unverified",
]);

const key = (shareId: string, what: "secret" | "attempt" | "joined" | "name" | "role" | "via") =>
  `cmux.guest.${shareId}.${what}`;
const role = (value: unknown): GuestRole | undefined => (value === "view" || value === "talk" ? value : undefined);

/**
 * Reads the share id from `/g/<id>` and the secret from the fragment, removes the fragment from
 * the URL (history.replaceState), and keeps the secret in `storage` until the redeem succeeds.
 * Undefined for a path that names no share.
 */
export function takeGuestLink(location: Location, history: History, storage: Storage): GuestLink | undefined {
  const match = /^\/([gi])\/([^/]+)\/?$/.exec(location.pathname);
  const shareId = match?.[2];
  if (!shareId || !ID.test(shareId)) return undefined;
  const fragment = location.hash.replace(/^#/, "");
  if (location.hash) history.replaceState(history.state, "", location.pathname + location.search);
  // An invite has no secret: whatever a fragment holds is dropped, never kept.
  if (match[1] === "i") return { shareId, invite: true };
  if (ID.test(fragment)) storage.setItem(key(shareId, "secret"), fragment);
  const secret = storage.getItem(key(shareId, "secret")) ?? undefined;
  return { shareId, ...(secret ? { secret } : {}) };
}

/** This tab's redeem attempt for the share: made once (128 random bits), reused on every retry. */
export function attemptId(
  shareId: string,
  storage: Storage,
  random = (bytes: Uint8Array) => crypto.getRandomValues(bytes),
): string {
  const kept = storage.getItem(key(shareId, "attempt"));
  if (kept) return kept;
  const bytes = random(new Uint8Array(16));
  const made = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  storage.setItem(key(shareId, "attempt"), made);
  return made;
}

/**
 * How this tab joined. A join kept before the kind was recorded was an invite exactly when it has a
 * role (the room names one only for an invitee).
 */
const joinedVia = (shareId: string, storage: Storage): JoinedVia => {
  const via = storage.getItem(key(shareId, "via"));
  if (via === "link" || via === "invite") return via;
  return storage.getItem(key(shareId, "role")) === null ? "link" : "invite";
};

/**
 * The guest id this tab joined the share as (its cookie is set), so a reload goes straight to the
 * chat. On an invite page (`invite`) only an invite's join counts: a tab that joined by the link is
 * an anonymous guest, so it accepts again as the account (and gets the invite's role).
 */
export const joinedAs = (shareId: string, storage: Storage, invite = false) => {
  if (invite && joinedVia(shareId, storage) !== "invite") return undefined;
  return storage.getItem(key(shareId, "joined")) ?? undefined;
};

/** The redeem worked: the secret and the attempt are spent, and the tab remembers it joined. */
/** The name this tab joined the share with. */
export const joinedName = (shareId: string, storage: Storage) => storage.getItem(key(shareId, "name")) ?? undefined;

/** The role this tab's invitee joined with, when the room named one (on an invite page, an invite's only). */
export const joinedRole = (shareId: string, storage: Storage, invite = false) =>
  invite && joinedVia(shareId, storage) !== "invite" ? undefined : role(storage.getItem(key(shareId, "role")));

export function rememberJoined(
  shareId: string,
  guestId: string,
  storage: Storage,
  name?: string,
  joinedAs?: GuestRole,
  via: JoinedVia = "link",
): void {
  storage.removeItem(key(shareId, "secret"));
  storage.removeItem(key(shareId, "attempt"));
  storage.setItem(key(shareId, "joined"), guestId);
  storage.setItem(key(shareId, "via"), via);
  if (name) storage.setItem(key(shareId, "name"), name);
  if (joinedAs) storage.setItem(key(shareId, "role"), joinedAs);
  else storage.removeItem(key(shareId, "role"));
}

/** A typed name as the guest may join with it: one line, 1 to 64 visible characters; else undefined. */
export function joinName(typed: string): string | undefined {
  const plain = typed.replace(/\s+/g, " ").trim();
  if (/[\r\n]/.test(typed) || Array.from(plain).length > 64) return undefined;
  // A control, bidi or zero-width character is refused, not quietly dropped (the daemon's rule).
  const name = displayName(typed);
  return name === plain ? name : undefined;
}

/** POSTs one join to the room, same origin, the cookie it sets kept (credentials include). */
const join =
  (fetcher: (url: string, init: RequestInit) => Promise<Response>, path: "redeem" | "accept") =>
  async (shareId: string, request: RedeemRequest | AcceptRequest): Promise<RedeemResult> => {
    let response: Response;
    try {
      response = await fetcher(`/v1/chat-shares/${encodeURIComponent(shareId)}/${path}`, {
        method: "POST",
        credentials: "include",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(request),
      });
    } catch {
      return { ok: false, error: "failed" };
    }
    const body = (await response.json().catch(() => ({}))) as Record<string, any>;
    if (response.ok && typeof body.guest_id === "string") {
      const joinedAs = role(body.role);
      return { ok: true, guestId: body.guest_id, ...(joinedAs ? { role: joinedAs } : {}) };
    }
    const code = String(body.error?.code ?? body.error ?? body.code ?? "");
    return { ok: false, error: KNOWN.has(code) ? (code as RedeemError) : "failed" };
  };

/** The room's redeem (a link's secret), over fetch. */
export const redeemOverFetch = (
  fetcher: (url: string, init: RequestInit) => Promise<Response> = (url, init) => fetch(url, init),
): Redeem => join(fetcher, "redeem");

/** The room's accept (an invite, as the signed-in account), over fetch: only the attempt id is sent. */
export const acceptOverFetch = (
  fetcher: (url: string, init: RequestInit) => Promise<Response> = (url, init) => fetch(url, init),
): Accept => join(fetcher, "accept");
