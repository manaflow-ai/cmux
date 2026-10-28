// Joining a shared chat (design/chat-multiplayer.md 3 and 4.3): the link is
// `/g/<share_id>#<secret>`. The secret never stays in the address bar: the page reads it and
// takes the fragment out of the URL at once. It is kept in this tab's sessionStorage only until
// the redeem succeeds, so a reload before Join still works. Redeem POSTs once, same origin, with an
// `attempt_id` kept in sessionStorage, so a retry after a lost reply is the same attempt and
// spends no second use.
import { displayName } from "../acpmux/multiplayer/participants";

/** A share or secret id as the daemon makes them: 128-bit, URL-safe. */
const ID = /^[A-Za-z0-9_-]{8,128}$/;

export type GuestLink = { shareId: string; secret?: string };

/** Errors the room answers a redeem with; anything else is `failed`. */
export type RedeemError =
  | "share.expired"
  | "share.revoked"
  | "share.used"
  | "share.kicked"
  | "share.left"
  | "share.host_offline"
  | "failed";
export type RedeemResult = { ok: true; guestId: string } | { ok: false; error: RedeemError };
export type RedeemRequest = { attempt_id: string; secret: string; name: string };
export type Redeem = (shareId: string, request: RedeemRequest) => Promise<RedeemResult>;

const KNOWN: ReadonlySet<string> = new Set([
  "share.expired",
  "share.revoked",
  "share.used",
  "share.kicked",
  "share.left",
  "share.host_offline",
]);

const key = (shareId: string, what: "secret" | "attempt" | "joined" | "name") => `cmux.guest.${shareId}.${what}`;

/**
 * Reads the share id from `/g/<id>` and the secret from the fragment, removes the fragment from
 * the URL (history.replaceState), and keeps the secret in `storage` until the redeem succeeds.
 * Undefined for a path that names no share.
 */
export function takeGuestLink(location: Location, history: History, storage: Storage): GuestLink | undefined {
  const match = /^\/g\/([^/]+)\/?$/.exec(location.pathname);
  const shareId = match?.[1];
  if (!shareId || !ID.test(shareId)) return undefined;
  const fragment = location.hash.replace(/^#/, "");
  if (location.hash) history.replaceState(history.state, "", location.pathname + location.search);
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

/** The guest id this tab joined the share as (its cookie is set), so a reload goes straight to the chat. */
export const joinedAs = (shareId: string, storage: Storage) => storage.getItem(key(shareId, "joined")) ?? undefined;

/** The redeem worked: the secret and the attempt are spent, and the tab remembers it joined. */
/** The name this tab joined the share with. */
export const joinedName = (shareId: string, storage: Storage) => storage.getItem(key(shareId, "name")) ?? undefined;

export function rememberJoined(shareId: string, guestId: string, storage: Storage, name?: string): void {
  storage.removeItem(key(shareId, "secret"));
  storage.removeItem(key(shareId, "attempt"));
  storage.setItem(key(shareId, "joined"), guestId);
  if (name) storage.setItem(key(shareId, "name"), name);
}

/** A typed name as the guest may join with it: one line, 1 to 64 visible characters; else undefined. */
export function joinName(typed: string): string | undefined {
  const plain = typed.replace(/\s+/g, " ").trim();
  if (/[\r\n]/.test(typed) || Array.from(plain).length > 64) return undefined;
  // A control, bidi or zero-width character is refused, not quietly dropped (the daemon's rule).
  const name = displayName(typed);
  return name === plain ? name : undefined;
}

/** The room's redeem, over fetch: same origin, the cookie it sets kept (credentials include). */
export const redeemOverFetch =
  (fetcher: (url: string, init: RequestInit) => Promise<Response> = (url, init) => fetch(url, init)): Redeem =>
  async (shareId, request) => {
    let response: Response;
    try {
      response = await fetcher(`/v1/chat-shares/${encodeURIComponent(shareId)}/redeem`, {
        method: "POST",
        credentials: "include",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(request),
      });
    } catch {
      return { ok: false, error: "failed" };
    }
    const body = (await response.json().catch(() => ({}))) as Record<string, any>;
    if (response.ok && typeof body.guest_id === "string") return { ok: true, guestId: body.guest_id };
    const code = String(body.error?.code ?? body.error ?? body.code ?? "");
    return { ok: false, error: KNOWN.has(code) ? (code as RedeemError) : "failed" };
  };
