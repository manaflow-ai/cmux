import { describe, expect, test } from "bun:test";
import { call, isDefinedError, ORPCError } from "@orpc/server";
import { z } from "zod";
import { dashboardOS, requireDashboardOrigin } from "../orpc/server/dashboard/base";
import { refusalFromResponse, teamRefusalFromError } from "../orpc/server/dashboard/errors";
import { callRoute } from "../orpc/server/dashboard/route-call";
import { TeamApiError, TeamGoneError, TeamServiceUnavailableError } from "../services/teams/errors";

const ORIGIN = "https://cmux.test";

function rpcRequest(headers: Record<string, string> = {}): Request {
  return new Request(`${ORIGIN}/api/dashboard/rpc/x`, {
    method: "POST",
    headers: { "content-type": "application/json", cookie: "session=abc", ...headers },
  });
}

describe("refusal translation", () => {
  test("maps both error envelopes to a typed refusal with the route's reason", async () => {
    const plain = await refusalFromResponse(Response.json({ error: "no_teams" }, { status: 409 }));
    expect([plain.code, plain.status, plain.data]).toEqual(["CONFLICT", 409, { reason: "no_teams" }]);
    const nested = await refusalFromResponse(
      Response.json({ error: { code: "last_admin", message: "Keep one admin." } }, { status: 409 }),
    );
    expect(nested.data).toEqual({ reason: "last_admin", message: "Keep one admin." });
    const bare = await refusalFromResponse(new Response("upstream", { status: 503 }));
    expect([bare.code, bare.data]).toEqual(["UNAVAILABLE", { reason: "http_503" }]);
  });

  test("a status outside the contract becomes an undeclared internal error", async () => {
    const error = await refusalFromResponse(Response.json({ error: "teapot" }, { status: 418 }));
    expect([error.code, error.status]).toEqual(["INTERNAL_SERVER_ERROR", 500]);
  });

  test("team service errors map the way runTeamRoute maps them", () => {
    const refused = teamRefusalFromError(new TeamApiError("last_admin", 409)) as ORPCError<string, unknown>;
    expect([refused.code, refused.data]).toEqual(["CONFLICT", { reason: "last_admin", message: "A team must keep at least one admin." }]);
    expect((teamRefusalFromError(new TeamGoneError()) as ORPCError<string, unknown>).data).toEqual({ reason: "team_not_found" });
    expect((teamRefusalFromError(new TeamServiceUnavailableError()) as ORPCError<string, unknown>).status).toBe(503);
    const other = new Error("boom");
    expect(teamRefusalFromError(other)).toBe(other);
  });
});

describe("route adapter", () => {
  test("forwards the caller's identity headers, params, search, and JSON body", async () => {
    let seen: { url: string; method: string; headers: Record<string, string>; body: unknown; params: unknown } | null = null;
    const handler = async (request: Request, context: { params: Promise<{ id: string }> }) => {
      seen = {
        url: request.url,
        method: request.method,
        headers: Object.fromEntries(request.headers),
        body: await request.json(),
        params: await context.params,
      };
      return Response.json({ renamed: true });
    };
    const result = await callRoute({ request: rpcRequest({ origin: ORIGIN }) }, handler, {
      method: "PATCH",
      path: "/api/vm/access-grants/g1",
      params: { id: "g1" },
      search: { teamId: "t1", skipped: null },
      headers: { "x-cmux-team-id": "t1" },
      body: { displayName: "Mac" },
    });
    expect(result).toEqual({ renamed: true });
    expect(seen!.url).toBe(`${ORIGIN}/api/vm/access-grants/g1?teamId=t1`);
    expect(seen!.method).toBe("PATCH");
    expect(seen!.params).toEqual({ id: "g1" });
    expect(seen!.body).toEqual({ displayName: "Mac" });
    expect(seen!.headers).toMatchObject({
      cookie: "session=abc",
      origin: ORIGIN,
      "x-cmux-team-id": "t1",
      "content-type": "application/json",
      accept: "application/json",
    });
  });

  test("204 is null and an error envelope throws the typed refusal", async () => {
    const context = { request: rpcRequest() };
    expect(await callRoute(context, async () => new Response(null, { status: 204 }), { method: "DELETE", path: "/x" })).toBeNull();
    const error = await callRoute(context, async () => Response.json({ error: "not_found" }, { status: 404 }), {
      method: "GET",
      path: "/x",
    }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ORPCError);
    expect((error as ORPCError<string, unknown>).data).toEqual({ reason: "not_found" });
  });
});

describe("origin guard", () => {
  const probe = dashboardOS.use(requireDashboardOrigin).output(z.literal("ran")).handler(() => "ran" as const);

  test("refuses a browser call without an allowed origin as a declared FORBIDDEN", async () => {
    const error = await call(probe, undefined, { context: { request: rpcRequest() } }).catch((caught: unknown) => caught);
    expect(isDefinedError(error)).toBe(true);
    expect((error as ORPCError<string, unknown>).code).toBe("FORBIDDEN");
    const crossSite = await call(probe, undefined, {
      context: { request: rpcRequest({ origin: "https://evil.example", "sec-fetch-site": "cross-site" }) },
    }).catch((caught: unknown) => caught);
    expect((crossSite as ORPCError<string, unknown>).code).toBe("FORBIDDEN");
  });

  test("accepts a same-origin browser call and the page's server prefetch", async () => {
    expect(await call(probe, undefined, { context: { request: rpcRequest({ origin: ORIGIN }) } })).toBe("ran");
    expect(await call(probe, undefined, { context: { request: new Request(`${ORIGIN}/dashboard`), serverPrefetch: true } }))
      .toBe("ran");
  });
});

describe("dashboard RPC endpoint", () => {
  test("a browser client gets a typed refusal and private no-store responses", async () => {
    const { createORPCClient, isDefinedError: isClientDefinedError, safe } = await import("@orpc/client");
    const { RPCLink } = await import("@orpc/client/fetch");
    const { POST } = await import("../app/api/dashboard/rpc/[[...rest]]/route");
    let cacheControl: string | null = null;
    const link = new RPCLink({
      url: `${ORIGIN}/api/dashboard/rpc`,
      fetch: async (request) => {
        const response = await POST(request as Request);
        cacheControl = response.headers.get("cache-control");
        return response;
      },
    });
    const client = createORPCClient<import("../dashboard-app/lib/rpc").DashboardClient>(link);
    const { error } = await safe(client.account.session());
    expect(isClientDefinedError(error)).toBe(true);
    if (!isClientDefinedError(error)) return;
    expect(error.code).toBe("FORBIDDEN");
    expect(error.data).toEqual({ reason: "forbidden" });
    expect(cacheControl).toBe("private, no-store");
  });
});
