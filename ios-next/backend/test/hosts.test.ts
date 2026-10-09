import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/crypto";
import { emailLogin, harness } from "./helpers";

async function pair(h: ReturnType<typeof harness>, accessToken: string) {
  const start = await h.call("POST", "/v1/hosts/pair/start", { body: { name: "Studio Mac", os: "macOS 27.0" } });
  const approve = await h.call("POST", "/v1/hosts/pair/approve", { token: accessToken, body: { userCode: start.json.userCode } });
  const poll = await h.call("POST", "/v1/hosts/pair/poll", { body: { deviceCode: start.json.deviceCode } });
  return { start, approve, poll };
}

describe("host pairing (device code)", () => {
  it("start -> pending -> approve -> approved once", async () => {
    const h = harness();
    const user = await emailLogin(h);
    const start = await h.call("POST", "/v1/hosts/pair/start", { body: { name: "Studio Mac", os: "macOS 27.0" } });
    expect(start.status).toBe(200);
    expect(start.json.deviceCode).toMatch(/^dc_/);
    expect(start.json.userCode).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    expect(start.json.interval).toBe(5);
    expect(start.json.expiresAt).toBe(h.clock.now + 10 * 60 * 1000);
    // Device codes are stored hashed.
    expect([...h.repo.pairings.values()][0]!.deviceCodeHash).toBe(await sha256Hex(start.json.deviceCode));

    expect((await h.call("POST", "/v1/hosts/pair/poll", { body: { deviceCode: start.json.deviceCode } })).json).toEqual({ status: "pending" });

    // Approve needs a user, accepts lowercase without the dash.
    expect((await h.call("POST", "/v1/hosts/pair/approve", { body: { userCode: start.json.userCode } })).status).toBe(401);
    const code = start.json.userCode.replace("-", "").toLowerCase();
    const approve = await h.call("POST", "/v1/hosts/pair/approve", { token: user.accessToken, body: { userCode: code } });
    expect(approve.status).toBe(200);
    expect(approve.json.host).toMatchObject({ name: "Studio Mac", os: "macOS 27.0", online: false, lastSeenAt: null });
    expect(approve.json.host.id).toMatch(/^h_/);

    // Approving twice fails.
    expect((await h.call("POST", "/v1/hosts/pair/approve", { token: user.accessToken, body: { userCode: code } })).status).toBe(404);

    const poll = await h.call("POST", "/v1/hosts/pair/poll", { body: { deviceCode: start.json.deviceCode } });
    expect(poll.json).toMatchObject({ status: "approved", hostId: approve.json.host.id, userId: user.user.id });
    expect(poll.json.hostToken).toMatch(/^ht_/);
    expect(h.repo.hosts.get(approve.json.host.id)!.tokenHash).toBe(await sha256Hex(poll.json.hostToken));

    // The token is handed out once.
    expect((await h.call("POST", "/v1/hosts/pair/poll", { body: { deviceCode: start.json.deviceCode } })).status).toBe(410);
  });

  it("expires pending pairings and rejects unknown codes", async () => {
    const h = harness();
    const user = await emailLogin(h);
    const start = await h.call("POST", "/v1/hosts/pair/start", { body: { name: "Mac", os: "macOS" } });
    h.clock.now += 10 * 60 * 1000 + 1;
    expect((await h.call("POST", "/v1/hosts/pair/poll", { body: { deviceCode: start.json.deviceCode } })).status).toBe(410);
    expect((await h.call("POST", "/v1/hosts/pair/approve", { token: user.accessToken, body: { userCode: start.json.userCode } })).status).toBe(404);
    expect((await h.call("POST", "/v1/hosts/pair/poll", { body: { deviceCode: "dc_unknown" } })).status).toBe(404);
    expect((await h.call("POST", "/v1/hosts/pair/start", { body: { name: "Mac" } })).status).toBe(400);
  });

  it("lists, scopes and deletes hosts", async () => {
    const h = harness();
    const alice = await emailLogin(h, "alice@example.com");
    const bob = await emailLogin(h, "bob@example.com");
    const { approve } = await pair(h, alice.accessToken);
    const list = await h.call("GET", "/v1/hosts", { token: alice.accessToken });
    expect(list.json.hosts).toHaveLength(1);
    expect(list.json.hosts[0]).toMatchObject({ id: approve.json.host.id, online: false });
    expect(Object.keys(list.json.hosts[0]).sort()).toEqual(["createdAt", "id", "lastSeenAt", "name", "online", "os"]);
    expect((await h.call("GET", "/v1/hosts", { token: bob.accessToken })).json.hosts).toHaveLength(0);
    expect((await h.call("DELETE", `/v1/hosts/${approve.json.host.id}`, { token: bob.accessToken })).status).toBe(404);
    expect((await h.call("DELETE", `/v1/hosts/${approve.json.host.id}`, { token: alice.accessToken })).status).toBe(200);
    expect((await h.call("GET", "/v1/hosts", { token: alice.accessToken })).json.hosts).toHaveLength(0);
  });

  it("host tokens authenticate /ice but not user routes", async () => {
    const h = harness();
    const user = await emailLogin(h);
    const { poll } = await pair(h, user.accessToken);
    expect((await h.call("GET", "/v1/ice", { token: poll.json.hostToken })).status).toBe(200);
    expect((await h.call("GET", "/v1/hosts", { token: poll.json.hostToken })).status).toBe(403);
    expect((await h.call("GET", "/v1/ice", { token: "ht_forged" })).status).toBe(401);
  });
});

describe("/ice", () => {
  it("returns Cloudflare STUN without TURN configured", async () => {
    const h = harness({ TURN_KEY_ID: undefined, TURN_KEY_API_TOKEN: undefined });
    const user = await emailLogin(h);
    expect((await h.call("GET", "/v1/ice")).status).toBe(401);
    const res = await h.call("GET", "/v1/ice", { token: user.accessToken });
    expect(res.json).toEqual({ iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }], ttl: 86400 });
    expect(h.outbound).toHaveLength(0);
  });

  it("adds Cloudflare TURN credentials when configured", async () => {
    const h = harness({ TURN_KEY_ID: "key1", TURN_KEY_API_TOKEN: "tok" });
    h.onFetch((url, init) => {
      if (url !== "https://rtc.live.cloudflare.com/v1/turn/keys/key1/credentials/generate-ice-servers") return undefined;
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer tok");
      expect(JSON.parse(String(init?.body))).toEqual({ ttl: 86400 });
      return Response.json(
        {
          iceServers: [
            { urls: ["stun:stun.cloudflare.com:3478"] },
            { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u", credential: "c" },
          ],
        },
        { status: 201 },
      );
    });
    const user = await emailLogin(h);
    const res = await h.call("GET", "/v1/ice", { token: user.accessToken });
    expect(res.json.iceServers).toEqual([
      { urls: ["stun:stun.cloudflare.com:3478"] },
      { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u", credential: "c" },
    ]);
  });

  it("falls back to STUN when the TURN API fails", async () => {
    const h = harness({ TURN_KEY_ID: "key1", TURN_KEY_API_TOKEN: "tok" });
    h.onFetch(() => new Response("nope", { status: 500 }));
    const user = await emailLogin(h);
    const res = await h.call("GET", "/v1/ice", { token: user.accessToken });
    expect(res.json.iceServers).toEqual([{ urls: ["stun:stun.cloudflare.com:3478"] }]);
  });
});
