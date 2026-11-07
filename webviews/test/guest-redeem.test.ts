// Joining a shared chat (agent-session/guest/redeem.ts): the secret leaves the address bar at
// once, a retry reuses the tab's attempt id, names follow the daemon's rule, and the room's
// errors map to what the page shows.
import { expect, test } from "bun:test";
import {
  acceptOverFetch,
  attemptId,
  joinedAs,
  joinedRole,
  joinName,
  redeemOverFetch,
  rememberJoined,
  takeGuestLink,
} from "../src/agent-session/guest/redeem";

class MemoryStorage {
  private items = new Map<string, string>();
  getItem = (key: string) => this.items.get(key) ?? null;
  setItem = (key: string, value: string) => void this.items.set(key, value);
  removeItem = (key: string) => void this.items.delete(key);
}
const storage = () => new MemoryStorage() as unknown as Storage;

function page(href: string) {
  const url = new URL(href);
  const replaced: string[] = [];
  const location = {
    get pathname() {
      return url.pathname;
    },
    get search() {
      return url.search;
    },
    get hash() {
      return url.hash;
    },
  } as Location;
  const history = {
    state: null,
    replaceState: (_: unknown, __: string, next: string) => {
      replaced.push(next);
      url.hash = "";
    },
  } as unknown as History;
  return { location, history, replaced, url };
}

const SHARE = "c2hhcmUtMTIzNDU2Nzg";
const SECRET = "c2VjcmV0LWFiY2RlZmdo";

test("the secret leaves the URL at once and stays in the tab until the redeem works", () => {
  const kept = storage();
  const open = page(`https://room.test/g/${SHARE}#${SECRET}`);
  expect(takeGuestLink(open.location, open.history, kept)).toEqual({ shareId: SHARE, secret: SECRET });
  expect(open.replaced).toEqual([`/g/${SHARE}`]);
  expect(open.url.href).toBe(`https://room.test/g/${SHARE}`);
  // A reload (no fragment now) still has the secret, until Join worked.
  const reload = page(`https://room.test/g/${SHARE}`);
  expect(takeGuestLink(reload.location, reload.history, kept)).toEqual({ shareId: SHARE, secret: SECRET });
  expect(reload.replaced).toEqual([]);
  expect(joinedAs(SHARE, kept)).toBeUndefined();
  rememberJoined(SHARE, "g1", kept);
  expect(joinedAs(SHARE, kept)).toBe("g1");
  expect(takeGuestLink(reload.location, reload.history, kept)).toEqual({ shareId: SHARE });
});

test("a path that names no share, or a malformed fragment, gives no link or no secret", () => {
  const other = page(`https://room.test/elsewhere#${SECRET}`);
  expect(takeGuestLink(other.location, other.history, storage())).toBeUndefined();
  const cut = page(`https://room.test/g/${SHARE}#x`);
  expect(takeGuestLink(cut.location, cut.history, storage())).toEqual({ shareId: SHARE });
  expect(cut.replaced).toEqual([`/g/${SHARE}`]);
});

test("a retry after a lost reply reuses the attempt id; a new share or a join makes a new one", () => {
  const kept = storage();
  let calls = 0;
  const random = (bytes: Uint8Array) => {
    calls += 1;
    return bytes.fill(calls);
  };
  const first = attemptId(SHARE, kept, random);
  expect(first).toMatch(/^[0-9a-f]{32}$/);
  expect(attemptId(SHARE, kept, random)).toBe(first);
  expect(attemptId("b3RoZXItc2hhcmU", kept, random)).not.toBe(first);
  rememberJoined(SHARE, "g1", kept);
  expect(attemptId(SHARE, kept, random)).not.toBe(first);
});

test("a name is one line of 1 to 64 visible characters", () => {
  expect(joinName("  Ana  ")).toBe("Ana");
  expect(joinName("Ana Lee")).toBe("Ana Lee");
  expect(joinName("")).toBeUndefined();
  expect(joinName("   ")).toBeUndefined();
  expect(joinName("a".repeat(64))).toBe("a".repeat(64));
  expect(joinName("a".repeat(65))).toBeUndefined();
  expect(joinName("Ana\nLee")).toBeUndefined();
  expect(joinName("Ana\u202eLee")).toBeUndefined();
  expect(joinName("Ana\u200bLee")).toBeUndefined();
});

test("redeem posts once, same origin with credentials, and maps the room's errors", async () => {
  const calls: [string, RequestInit][] = [];
  const answer = (status: number, body: unknown) =>
    redeemOverFetch(async (url, init) => {
      calls.push([String(url), init!]);
      return new Response(JSON.stringify(body), { status });
    });
  const request = { attempt_id: "a".repeat(32), secret: SECRET, name: "Ana" };
  expect(await answer(200, { guest_id: "g1" })(SHARE, request)).toEqual({ ok: true, guestId: "g1" });
  expect(calls[0]![0]).toBe(`/v1/chat-shares/${SHARE}/redeem`);
  expect(calls[0]![1].method).toBe("POST");
  expect(calls[0]![1].credentials).toBe("include");
  expect(JSON.parse(String(calls[0]![1].body))).toEqual(request);
  for (const code of [
    "share.expired",
    "share.revoked",
    "share.closed",
    "share.used",
    "share.kicked",
    "share.host_offline",
  ] as const)
    expect(await answer(409, { error: { code } })(SHARE, request)).toEqual({ ok: false, error: code });
  expect(await answer(429, { error: "rate_limited" })(SHARE, request)).toEqual({ ok: false, error: "failed" });
  const offline = redeemOverFetch(() => Promise.reject(new TypeError("offline")));
  expect(await offline(SHARE, request)).toEqual({ ok: false, error: "failed" });
});

test("an invite link /i/<id> names the share and is an invite; it carries no secret", () => {
  const kept = storage();
  const open = page(`https://room.test/i/${SHARE}#${SECRET}`);
  expect(takeGuestLink(open.location, open.history, kept)).toEqual({ shareId: SHARE, invite: true });
  // Nothing of a fragment is kept: an invite's only credential is the account's sign-in.
  expect(kept.getItem(`cmux.guest.${SHARE}.secret`)).toBeNull();
  expect(open.replaced).toEqual([`/i/${SHARE}`]);
  const plain = page(`https://room.test/i/${SHARE}`);
  expect(takeGuestLink(plain.location, plain.history, kept)).toEqual({ shareId: SHARE, invite: true });
  expect(plain.replaced).toEqual([]);
});

test("a join remembers the invite's role for a reload", () => {
  const kept = storage();
  expect(joinedRole(SHARE, kept)).toBeUndefined();
  rememberJoined(SHARE, "g1", kept, undefined, "view");
  expect(joinedAs(SHARE, kept)).toBe("g1");
  expect(joinedRole(SHARE, kept)).toBe("view");
  rememberJoined(SHARE, "g1", kept, "Ana");
  expect(joinedRole(SHARE, kept)).toBeUndefined();
});

test("accept posts only the attempt, same origin with credentials, and maps the room's role and errors", async () => {
  const calls: [string, RequestInit][] = [];
  const answer = (status: number, body: unknown) =>
    acceptOverFetch(async (url, init) => {
      calls.push([String(url), init!]);
      return new Response(JSON.stringify(body), { status });
    });
  const request = { attempt_id: "a".repeat(32) };
  expect(await answer(200, { guest_id: "g1", role: "view" })(SHARE, request)).toEqual({
    ok: true,
    guestId: "g1",
    role: "view",
  });
  expect(calls[0]![0]).toBe(`/v1/chat-shares/${SHARE}/accept`);
  expect(calls[0]![1].method).toBe("POST");
  expect(calls[0]![1].credentials).toBe("include");
  // No account or name: the room takes both from the sign-in.
  expect(JSON.parse(String(calls[0]![1].body))).toEqual(request);
  expect(await answer(200, { guest_id: "g1", role: "admin" })(SHARE, request)).toEqual({ ok: true, guestId: "g1" });
  for (const code of ["share.not_invited", "share.unauthorized", "share.unverified", "share.kicked"] as const)
    expect(await answer(403, { code })(SHARE, request)).toEqual({ ok: false, error: code });
});

test("a tab that joined by the link still accepts on the invite page; an invite join opens both", () => {
  const kept = storage();
  // Joined /g/<id> by the link: that guest is anonymous, so /i/<id> must accept as the account.
  rememberJoined(SHARE, "link-guest", kept, "Ana");
  expect(joinedAs(SHARE, kept)).toBe("link-guest");
  expect(joinedAs(SHARE, kept, true)).toBeUndefined();
  expect(joinedRole(SHARE, kept, true)).toBeUndefined();
  // The accept replaces it: the invite's guest and role, on either page.
  rememberJoined(SHARE, "invitee", kept, undefined, "view", "invite");
  expect(joinedAs(SHARE, kept, true)).toBe("invitee");
  expect(joinedRole(SHARE, kept, true)).toBe("view");
  expect(joinedAs(SHARE, kept)).toBe("invitee");
  expect(joinedRole(SHARE, kept)).toBe("view");
  // A tab that joined before the join kind was kept: a role says it was an invite.
  const before = storage();
  before.setItem(`cmux.guest.${SHARE}.joined`, "old-invitee");
  before.setItem(`cmux.guest.${SHARE}.role`, "talk");
  expect(joinedAs(SHARE, before, true)).toBe("old-invitee");
  before.removeItem(`cmux.guest.${SHARE}.role`);
  expect(joinedAs(SHARE, before, true)).toBeUndefined();
});
