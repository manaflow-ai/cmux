/**
 * Client session identities on the tenant API (cx-b4h.6): the team-wide list,
 * read one session, change its Linux user, and list, mint and revoke its
 * tokens. A tenant reaches only sessions cmux minted for its own VMs, tokens
 * are shown once, token ids are cmux ids (never the provider's), and a session
 * is never granted an unrestricted Linux user.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const UPSTREAM_KEY = "upstream-test-key";
const EXEC = ["vm:read", "vm:write", "vm:exec"] as const;

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

interface SessionBody {
  readonly id: string;
  readonly token: string;
  readonly tokenId: string;
  readonly vmId: string;
  readonly providerVmId: string;
  readonly linuxUser: string;
  readonly ssh: { readonly host: string; readonly user: string };
}

interface TokenBody {
  readonly id: string;
  readonly sessionId: string;
  readonly vmId: string;
  readonly token: string;
  readonly providerVmId: string;
  readonly linuxUser: string;
  readonly apiBaseUrl: string;
  readonly ssh: { readonly host: string; readonly user: string };
}

const open = async (secret: string, vmId: string, body: Record<string, unknown> = {}, headers: Record<string, string> = {}) => {
  const response = await h.request(`/v1/vms/${vmId}/client-session`, { ...bearer(secret), ...headers }, { method: "POST", body });
  expect(response.status).toBe(201);
  return response.json<SessionBody>();
};

const sessionPath = (vmId: string, sessionId: string) => `/v1/vms/${vmId}/client-sessions/${sessionId}`;

describe("one session", () => {
  it("reads a live session without its token, and 404s once revoked", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId, { linuxUser: "cmux" });

    const read = await h.request(sessionPath(vmId, session.id), bearer(key));
    expect(read.status).toBe(200);
    const text = await read.text();
    expect(text).not.toContain(session.token);
    expect(text).not.toContain(session.providerVmId);
    expect(JSON.parse(text)).toMatchObject({ id: session.id, vmId, linuxUser: "cmux" });

    expect((await h.request(sessionPath(vmId, session.id), bearer(key), { method: "DELETE" })).status).toBe(204);
    expect((await h.request(sessionPath(vmId, session.id), bearer(key))).status).toBe(404);
  });

  it("is reachable only through its own VM", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const first = h.addVm(TENANT_A);
    const second = h.addVm(TENANT_A);
    const session = await open(key, first.vmId);
    expect((await h.request(sessionPath(second.vmId, session.id), bearer(key))).status).toBe(404);
    expect((await h.request(`${sessionPath(second.vmId, session.id)}/tokens`, bearer(key))).status).toBe(404);
    expect((await h.request(`${sessionPath(second.vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).status).toBe(404);
    expect((await h.request(sessionPath(first.vmId, "vcs_bad"), bearer(key))).status).toBe(404);
  });
});

describe("changing the Linux user", () => {
  it("replaces the grant's one user on exactly this VM, for existing tokens too", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    expect(session.linuxUser).toBe("ubuntu");

    const changed = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body: { linuxUser: "cmux" } });
    expect(changed.status).toBe(200);
    expect(await changed.json()).toMatchObject({ id: session.id, vmId, linuxUser: "cmux" });
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["cmux"] }]);
    expect(h.clientSessions.find((row) => row.id === session.id)?.linuxUser).toBe("cmux");
    expect(h.audit).toContainEqual(expect.objectContaining({ action: "vm.client_session_linux_user", cmuxId: vmId, outcome: "ok" }));

    const listed = await (await h.request(`/v1/vms/${vmId}/client-sessions`, bearer(key))).json<{ sessions: ReadonlyArray<{ linuxUser: string }> }>();
    expect(listed.sessions.map((row) => row.linuxUser)).toEqual(["cmux"]);
    const minted = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).json<TokenBody>();
    expect(minted).toMatchObject({ linuxUser: "cmux", ssh: { user: `${upstreamId}+cmux` } });
  });

  it("never sends an unrestricted grant: a missing, null, list or malformed user is 400 and reaches nothing upstream", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    const before = h.upstream.callsTo("PATCH", /permissions\/vm/).length;
    for (const body of [{}, { linuxUser: null }, { linuxUser: ["ubuntu", "root"] }, { linuxUser: "bad user" }, { linuxUser: "" }]) {
      const response = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body });
      expect(response.status).toBe(400);
    }
    expect(h.upstream.callsTo("PATCH", /permissions\/vm/)).toHaveLength(before);
    for (const call of h.upstream.callsTo("PATCH", /permissions\/vm/)) {
      expect(call.json).toEqual({ allowedLinuxUsers: [expect.any(String)] });
    }
  });

  it("keeps the recorded user when the provider refuses", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    h.upstream.fail("updateVmAllowedLinuxUsers", 500);
    const response = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body: { linuxUser: "cmux" } });
    expect(response.status).toBe(503);
    expect(h.clientSessions.find((row) => row.id === session.id)?.linuxUser).toBe("ubuntu");
  });

  it("keeps the recorded user and the provider grant equal when a concurrent change wins the race", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    const original = h.upstream.fetch;
    let raced = false;
    // Right after this request's grant write, another change (to "bob") writes the grant and the table, as a
    // concurrent PUT that started later but recorded first would.
    h.upstream.fetch = async (request: Request) => {
      const response = await original(request);
      if (!raced && request.method === "PATCH" && /permissions\/vm/u.test(new URL(request.url).pathname)) {
        raced = true;
        await original(new Request(request.url, { method: "PATCH", headers: request.headers, body: JSON.stringify({ allowedLinuxUsers: ["bob"] }) }));
        const index = h.clientSessions.findIndex((row) => row.id === session.id);
        const row = h.clientSessions[index];
        if (row !== undefined) h.clientSessions[index] = { ...row, linuxUser: "bob" };
      }
      return response;
    };
    const response = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body: { linuxUser: "cmux" } });
    h.upstream.fetch = original;
    expect(response.status).toBe(409);
    expect(h.clientSessions.find((row) => row.id === session.id)?.linuxUser).toBe("bob");
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["bob"] }]);
    const minted = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).json<TokenBody>();
    expect(minted.ssh.user).toBe(`${upstreamId}+bob`);
  });

  it("re-applies the recorded user before the next token when a grant write failed after it applied", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    const original = h.upstream.fetch;
    // The provider applies the grant but the answer is lost (500): the provider now says "cmux".
    h.upstream.fetch = async (request: Request) => {
      const response = await original(request);
      return request.method === "PATCH" && /permissions\/vm/u.test(new URL(request.url).pathname) ? new Response("lost", { status: 500 }) : response;
    };
    const response = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body: { linuxUser: "cmux" } });
    h.upstream.fetch = original;
    expect(response.status).toBe(503);
    expect(h.clientSessions.find((row) => row.id === session.id)?.linuxUser).toBe("ubuntu");
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["cmux"] }]);
    // The next credential closes the drift first: the grant is the recorded user again.
    const minted = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).json<TokenBody>();
    expect(minted).toMatchObject({ linuxUser: "ubuntu", ssh: { user: `${upstreamId}+ubuntu` } });
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["ubuntu"] }]);
  });

  it("re-applies the recorded user before the next token when a change was cut off between recording and granting", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    // A change recorded "cmux" and its request ended before the grant write.
    const index = h.clientSessions.findIndex((row) => row.id === session.id);
    const row = h.clientSessions[index];
    if (row === undefined) throw new Error("no session");
    h.clientSessions[index] = { ...row, linuxUser: "cmux" };
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["ubuntu"] }]);
    const minted = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).json<TokenBody>();
    expect(minted).toMatchObject({ linuxUser: "cmux", ssh: { user: `${upstreamId}+cmux` } });
    expect(h.upstream.identityGrants(minted.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["cmux"] }]);
  });

  it("a change that loses the record never writes the provider grant", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    const before = h.upstream.callsTo("PATCH", /permissions\/vm/).length;
    // Another change records "bob" right after this request read the session.
    let raced = false;
    const index = h.clientSessions.findIndex((row) => row.id === session.id);
    const stored = h.clientSessions[index];
    if (stored === undefined) throw new Error("no session");
    const findSession = h.clientSessions.find.bind(h.clientSessions);
    Object.assign(h.clientSessions, {
      find: (predicate: Parameters<typeof findSession>[0]) => {
        const found = findSession(predicate);
        if (!raced && found?.id === session.id) {
          raced = true;
          h.clientSessions[index] = { ...stored, linuxUser: "bob" };
        }
        return found;
      },
    });
    const response = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body: { linuxUser: "cmux" } });
    Reflect.deleteProperty(h.clientSessions, "find");
    expect(raced).toBe(true);
    expect(response.status).toBe(409);
    expect(h.upstream.callsTo("PATCH", /permissions\/vm/)).toHaveLength(before);
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["ubuntu"] }]);
  });

  it("is 404 for a revoked session", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    await h.request(sessionPath(vmId, session.id), bearer(key), { method: "DELETE" });
    const response = await h.request(`${sessionPath(vmId, session.id)}/linux-user`, bearer(key), { method: "PUT", body: { linuxUser: "cmux" } });
    expect(response.status).toBe(404);
  });
});

describe("tokens", () => {
  it("lists the first token by the id the session returned, never the token or the provider's id", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    expect(session.tokenId).toMatch(/^vct_[0-9a-hjkmnp-tv-z]{26}$/);

    const listed = await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key));
    expect(listed.status).toBe(200);
    const text = await listed.text();
    expect(text).not.toContain(session.token);
    expect(text).not.toContain(UPSTREAM_KEY);
    for (const providerTokenId of h.upstream.identityTokenIds(session.token)) expect(text).not.toContain(providerTokenId);
    expect(JSON.parse(text)).toEqual({ tokens: [{ id: session.tokenId, sessionId: session.id }] });
  });

  it("mints another token for the same VM and user, shown once with the SSH login", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const session = await open(key, vmId, { linuxUser: "cmux" });

    const response = await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" });
    expect(response.status).toBe(201);
    const text = await response.text();
    expect(text).not.toContain(UPSTREAM_KEY);
    const minted: TokenBody = JSON.parse(text);
    expect(minted).toMatchObject({ sessionId: session.id, vmId, providerVmId: upstreamId, linuxUser: "cmux" });
    expect(minted.ssh).toEqual({ host: session.ssh.host, user: `${upstreamId}+cmux` });
    expect(minted.id).toMatch(/^vct_/);
    expect(minted.id).not.toBe(session.tokenId);
    expect(minted.token).not.toBe(session.token);
    expect(h.upstream.tokenValid(minted.token)).toBe(true);
    // Same identity, so the same one grant: one VM, one user.
    expect(h.upstream.identityGrants(minted.token)).toEqual([{ vmId: upstreamId, allowedLinuxUsers: ["cmux"] }]);
    expect(h.upstream.identityCount()).toBe(1);
    expect(h.audit).toContainEqual(expect.objectContaining({ action: "vm.client_session_token", cmuxId: vmId, outcome: "ok" }));

    const listed = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key))).json<{ tokens: ReadonlyArray<{ id: string }> }>();
    expect(listed.tokens.map((token) => token.id).sort()).toEqual([session.tokenId, minted.id].sort());
    expect(JSON.stringify(listed)).not.toContain(minted.token);
  });

  it("revokes one token and keeps the session and its other tokens; revoking again is not an error", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    const minted = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).json<TokenBody>();

    const revoked = await h.request(`${sessionPath(vmId, session.id)}/tokens/${session.tokenId}`, bearer(key), { method: "DELETE" });
    expect(revoked.status).toBe(204);
    expect(h.upstream.tokenValid(session.token)).toBe(false);
    expect(h.upstream.tokenValid(minted.token)).toBe(true);
    expect((await h.request(sessionPath(vmId, session.id), bearer(key))).status).toBe(200);
    const listed = await (await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key))).json<{ tokens: ReadonlyArray<{ id: string }> }>();
    expect(listed.tokens.map((token) => token.id)).toEqual([minted.id]);
    expect(h.audit).toContainEqual(expect.objectContaining({ action: "vm.client_session_token_revoke", cmuxId: vmId, outcome: "ok" }));

    expect((await h.request(`${sessionPath(vmId, session.id)}/tokens/${session.tokenId}`, bearer(key), { method: "DELETE" })).status).toBe(204);
    expect((await h.request(`${sessionPath(vmId, session.id)}/tokens/not-a-token`, bearer(key), { method: "DELETE" })).status).toBe(404);
  });

  it("cannot revoke another session's token through this session", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const mine = await open(key, vmId);
    const other = await open(key, vmId);
    const response = await h.request(`${sessionPath(vmId, mine.id)}/tokens/${other.tokenId}`, bearer(key), { method: "DELETE" });
    expect(response.status).toBe(204);
    expect(h.upstream.tokenValid(other.token)).toBe(true);
    expect(h.upstream.tokenValid(mine.token)).toBe(true);
  });

  it("are gone with their session: listing, minting and revoking a revoked session's tokens is 404", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    await h.request(sessionPath(vmId, session.id), bearer(key), { method: "DELETE" });
    const before = h.upstreamRequests.length;
    expect((await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key))).status).toBe(404);
    expect((await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).status).toBe(404);
    expect((await h.request(`${sessionPath(vmId, session.id)}/tokens/${session.tokenId}`, bearer(key), { method: "DELETE" })).status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
  });

  it("answers 503 when the provider fails to mint, and leaves the session usable", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(key, vmId);
    h.upstream.fail("createAccessToken", 500);
    expect((await h.request(`${sessionPath(vmId, session.id)}/tokens`, bearer(key), { method: "POST" })).status).toBe(503);
    expect(h.upstream.tokenValid(session.token)).toBe(true);
  });
});

describe("tenant isolation", () => {
  it("another tenant's key with every scope gets 404 on every session route, even with the right session and token ids", async () => {
    const keyA = await h.addKey(TENANT_A, EXEC);
    const keyB = await h.addKey(TENANT_B, ["vm:read", "vm:write", "vm:exec", "admin"]);
    const { vmId } = h.addVm(TENANT_A);
    const session = await open(keyA, vmId);
    const before = h.upstreamRequests.length;
    const routes: ReadonlyArray<readonly [string, string, unknown]> = [
      ["GET", sessionPath(vmId, session.id), undefined],
      ["PUT", `${sessionPath(vmId, session.id)}/linux-user`, { linuxUser: "root" }],
      ["GET", `${sessionPath(vmId, session.id)}/tokens`, undefined],
      ["POST", `${sessionPath(vmId, session.id)}/tokens`, undefined],
      ["DELETE", `${sessionPath(vmId, session.id)}/tokens/${session.tokenId}`, undefined],
    ];
    for (const [method, path, body] of routes) {
      const response = await h.request(path, bearer(keyB), { method, body });
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ _tag: "NotFound", message: "VM not found" });
    }
    expect(h.upstreamRequests).toHaveLength(before);
    expect(h.upstream.tokenValid(session.token)).toBe(true);
    expect(h.upstream.identityGrants(session.token)).toEqual([expect.objectContaining({ allowedLinuxUsers: ["ubuntu"] })]);
  });

  it("the team-wide list shows only the caller's tenant's live sessions on live VMs, never tokens", async () => {
    const keyA = await h.addKey(TENANT_A, EXEC);
    const keyB = await h.addKey(TENANT_B, EXEC);
    const a1 = h.addVm(TENANT_A);
    const a2 = h.addVm(TENANT_A);
    const b1 = h.addVm(TENANT_B);
    const s1 = await open(keyA, a1.vmId);
    const s2 = await open(keyA, a2.vmId, { linuxUser: "cmux" });
    const revoked = await open(keyA, a2.vmId);
    const sb = await open(keyB, b1.vmId);
    await h.request(sessionPath(a2.vmId, revoked.id), bearer(keyA), { method: "DELETE" });

    const listA = await h.request("/v1/client-sessions", bearer(keyA));
    expect(listA.status).toBe(200);
    const text = await listA.text();
    for (const session of [s1, s2, revoked, sb]) expect(text).not.toContain(session.token);
    expect(text).not.toContain(sb.id);
    const body: { sessions: ReadonlyArray<{ id: string; vmId: string; linuxUser: string }>; nextCursor: string | null } = JSON.parse(text);
    expect(body.sessions.map((row) => row.id).sort()).toEqual([s1.id, s2.id].sort());
    expect(body.sessions.find((row) => row.id === s2.id)).toMatchObject({ vmId: a2.vmId, linuxUser: "cmux" });
    expect(body.nextCursor).toBeNull();

    const listB = await (await h.request("/v1/client-sessions", bearer(keyB))).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(listB.sessions.map((row) => row.id)).toEqual([sb.id]);

    expect((await h.request(`/v1/vms/${a1.vmId}`, bearer(keyA), { method: "DELETE" })).status).toBe(204);
    const after = await (await h.request("/v1/client-sessions", bearer(keyA))).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(after.sessions.map((row) => row.id)).toEqual([s2.id]);
  });

  it("the team-wide list pages by cursor", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const { vmId } = h.addVm(TENANT_A);
    const ids = [(await open(key, vmId)).id, (await open(key, vmId)).id, (await open(key, vmId)).id].sort();
    const first = await (await h.request("/v1/client-sessions?limit=2", bearer(key))).json<{ sessions: ReadonlyArray<{ id: string }>; nextCursor: string | null }>();
    expect(first.sessions.map((row) => row.id)).toEqual(ids.slice(0, 2));
    expect(first.nextCursor).toBe(ids[1]);
    const second = await (await h.request(`/v1/client-sessions?limit=2&cursor=${first.nextCursor}`, bearer(key))).json<{ sessions: ReadonlyArray<{ id: string }>; nextCursor: string | null }>();
    expect(second.sessions.map((row) => row.id)).toEqual(ids.slice(2));
    expect(second.nextCursor).toBeNull();
    expect((await h.request("/v1/client-sessions?limit=0", bearer(key))).status).toBe(400);
    expect((await h.request("/v1/client-sessions?cursor=nope", bearer(key))).status).toBe(400);
  });

  it("the team-wide list needs vm:exec", async () => {
    const key = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const response = await h.request("/v1/client-sessions", bearer(key));
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ _tag: "Forbidden", missingScope: "vm:exec" });
  });

  it("a resource-allowlisted key lists only its VMs' sessions", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const mine = h.addVm(TENANT_A);
    const other = h.addVm(TENANT_A);
    const inside = await open(key, mine.vmId);
    await open(key, other.vmId);
    const limited = await h.addKey(TENANT_A, EXEC, { allowlist: [mine.vmId] });
    const listed = await (await h.request("/v1/client-sessions", bearer(limited))).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(listed.sessions.map((row) => row.id)).toEqual([inside.id]);
  });

  it("a service key lists and reaches only sessions on VMs carrying its labels", async () => {
    const key = await h.addKey(TENANT_A, EXEC);
    const chief = h.addVm(TENANT_A, "running", { role: "chief" });
    const plain = h.addVm(TENANT_A);
    const chiefSession = await open(key, chief.vmId);
    const plainSession = await open(key, plain.vmId);
    const service = await h.addServiceKey();
    const asTeam = { ...bearer(service), "x-cmux-team-id": TENANT_A };

    const listed = await (await h.request("/v1/client-sessions", asTeam)).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(listed.sessions.map((row) => row.id)).toEqual([chiefSession.id]);
    expect((await h.request(sessionPath(chief.vmId, chiefSession.id), asTeam)).status).toBe(200);
    expect((await h.request(sessionPath(plain.vmId, plainSession.id), asTeam)).status).toBe(404);
    expect((await h.request(`${sessionPath(plain.vmId, plainSession.id)}/tokens`, asTeam, { method: "POST" })).status).toBe(404);
  });

  it("an agent key reaches only its own VMs' sessions", async () => {
    const issuer = await h.addKey(TENANT_A, EXEC);
    const agentResponse = await h.request("/v1/agent-keys", bearer(issuer), { method: "POST", body: { name: "a" } });
    const agent = await agentResponse.json<{ key: string }>();
    const own = await (await h.request("/v1/vms", bearer(agent.key), { method: "POST", body: {} })).json<{ id: string }>();
    const teamVm = h.addVm(TENANT_A);
    const ownSession = await open(agent.key, own.id);
    const teamSession = await open(issuer, teamVm.vmId);

    const listed = await (await h.request("/v1/client-sessions", bearer(agent.key))).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(listed.sessions.map((row) => row.id)).toEqual([ownSession.id]);
    expect((await h.request(sessionPath(teamVm.vmId, teamSession.id), bearer(agent.key))).status).toBe(404);
    const issuerList = await (await h.request("/v1/client-sessions", bearer(issuer))).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(issuerList.sessions.map((row) => row.id).sort()).toEqual([ownSession.id, teamSession.id].sort());
  });
});
