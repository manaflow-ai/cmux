// Joining a shared chat (agent-session/guest/redeem.ts): the secret leaves the address bar at
// once, a retry reuses the tab's attempt id, names follow the daemon's rule, and the room's
// errors map to what the page shows.
import { expect, test } from "bun:test";
import {
  attemptId,
  joinedAs,
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
