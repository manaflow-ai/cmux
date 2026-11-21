import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { syncStoreProbe } from "./cloud-journey";

const PLATFORM = "https://platform.test";
const TOKEN = "install-token";
const GRANT = "csg_grant-for-tests";
const sha = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

/** A store in memory, as the platform's /v1/sync serves it. `serves` turns routes off to model older stores. */
function fakeStore(serves: { store?: boolean; roots?: boolean; usage?: boolean } = {}) {
  const { store = true, roots = true, usage = true } = serves;
  const blobs = new Map<string, Uint8Array>();
  const registered: Array<{ pair: string; tree: string }> = [];
  const calls: string[] = [];
  const answer = (status: number, body: unknown) => new Response(body instanceof Uint8Array ? body : JSON.stringify(body), { status });
  const fetcher = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const route = url.pathname;
    calls.push(`${method} ${route}`);
    const bearer = new Headers(init?.headers).get("authorization")?.replace(/^Bearer /, "");
    if (!store) return answer(404, { code: "sync.not_found" });
    const body = init?.body ? new Uint8Array(init.body instanceof Uint8Array ? init.body : new TextEncoder().encode(String(init.body))) : new Uint8Array();
    if (method === "GET" && route.startsWith("/v1/sync/blobs/")) {
      if (bearer !== GRANT && bearer !== TOKEN) return answer(401, { code: "sync.unauthorized" });
      const blob = blobs.get(route.slice("/v1/sync/blobs/".length));
      return blob ? answer(200, blob) : answer(404, { code: "sync.blob_not_found" });
    }
    if (bearer !== TOKEN) return answer(401, { code: "sync.unauthorized" });
    if (method === "POST" && route === "/v1/sync/blobs/missing") {
      const asked: string[] = JSON.parse(new TextDecoder().decode(body)).sha256;
      return answer(200, { missing: asked.filter((hash) => !blobs.has(hash)) });
    }
    if (method === "PUT" && route.startsWith("/v1/sync/blobs/")) {
      const hash = route.slice("/v1/sync/blobs/".length);
      if (sha(body) !== hash) return answer(400, { code: "sync.digest_mismatch" });
      blobs.set(hash, body);
      return answer(200, {});
    }
    if (method === "POST" && route === "/v1/sync/grants") return answer(200, { grant: GRANT, expiresAt: "2099-01-01T00:00:00Z" });
    if (method === "POST" && route === "/v1/sync/roots" && roots) {
      const asked = JSON.parse(new TextDecoder().decode(body));
      const tree = blobs.get(asked.tree);
      if (!tree) return answer(404, { code: "sync.blob_not_found" });
      if (!new TextDecoder().decode(tree).startsWith("cmux-sync-tree 1\n")) return answer(400, { code: "sync.bad_tree" });
      registered.push({ pair: asked.pair, tree: asked.tree });
      return answer(200, { pair: asked.pair, tree: asked.tree });
    }
    if (method === "GET" && route === "/v1/sync/usage" && usage) {
      const used = [...blobs.values()].reduce((sum, blob) => sum + blob.length, 0);
      return answer(200, { usedBytes: used, limitBytes: 200 * 1024 ** 3, roots: registered.length, gc: { mode: "dry-run" } });
    }
    return answer(404, { code: "not_found" });
  }) as typeof fetch;
  return { fetcher, blobs, registered, calls };
}

describe("sync store step", () => {
  test("a served store takes a blob, reads it back with a grant, registers a root naming it and reports usage", async () => {
    const store = fakeStore();
    const probe = await syncStoreProbe(PLATFORM, TOKEN, "tag1", store.fetcher);
    expect(probe.skip).toBeUndefined();
    expect(store.registered).toHaveLength(1);
    expect(store.registered[0].pair).toBe("journey-tag1");
    const tree = new TextDecoder().decode(store.blobs.get(store.registered[0].tree)!);
    const lines = tree.split("\n");
    expect(lines[0]).toBe("cmux-sync-tree 1");
    expect(store.blobs.has(lines[1])).toBe(true);
    expect(store.blobs.get(lines[1])!.length).toBe(4096);
    expect(probe.detail).toContain(`limitBytes ${200 * 1024 ** 3}`);
    expect(probe.detail).toContain("roots 1");
    expect(probe.detail).toContain("gc.mode dry-run");
    expect(store.calls).toEqual([
      "POST /v1/sync/blobs/missing",
      `PUT /v1/sync/blobs/${lines[1]}`,
      "POST /v1/sync/blobs/missing",
      "POST /v1/sync/grants",
      `GET /v1/sync/blobs/${lines[1]}`,
      `PUT /v1/sync/blobs/${store.registered[0].tree}`,
      "POST /v1/sync/roots",
      "GET /v1/sync/usage",
    ]);
  });

  test("a backend that serves no store is a skip, after one request", async () => {
    const store = fakeStore({ store: false });
    const probe = await syncStoreProbe(PLATFORM, TOKEN, "tag2", store.fetcher);
    expect(probe.skip).toBe("store off on this backend");
    expect(store.calls).toHaveLength(1);
  });

  test("a store from before GC roots checks the blob path and skips the rest", async () => {
    for (const serves of [{ roots: false }, { usage: false }]) {
      const store = fakeStore(serves);
      const probe = await syncStoreProbe(PLATFORM, TOKEN, "tag3", store.fetcher);
      expect(probe.skip).toContain("serves no /v1/sync/");
      expect(probe.detail).toContain("read back with a grant");
    }
  });

  test("a store that refuses the install token fails the step", async () => {
    const store = fakeStore();
    await expect(syncStoreProbe(PLATFORM, "someone-else", "tag4", store.fetcher)).rejects.toThrow(/missing \(before\): HTTP 401/);
  });
});
