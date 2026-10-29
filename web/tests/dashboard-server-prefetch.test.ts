import { beforeEach, describe, expect, mock, test } from "bun:test";
import { ORPCError, os } from "@orpc/server";
import { hydrate, QueryClient } from "@tanstack/react-query";

let sessionStatus = 200;
const calls: string[] = [];

const session = {
  user: {
    id: "user-1",
    displayName: null,
    primaryEmail: "me@example.com",
    primaryEmailVerified: true,
    profileImageUrl: null,
    selectedTeamId: null,
  },
  flags: { vaultEnabled: true },
};

mock.module("@/orpc/server/dashboard/router", () => ({
  dashboardRouter: {
    account: {
      session: os.handler(() => {
        calls.push("account.session");
        if (sessionStatus !== 200) throw new ORPCError("UNAUTHORIZED", { status: sessionStatus });
        return session;
      }),
      billing: os.handler(({ input }) => {
        calls.push(`account.billing:${JSON.stringify(input)}`);
        return { selectedTeamId: "team-1", personal: null, team: null, teams: [] };
      }),
    },
    teams: {
      detail: os.handler(() => {
        calls.push("teams.detail");
        throw new ORPCError("FORBIDDEN", { status: 403 });
      }),
    },
  },
}));

const { prefetchDashboard } = await import("../dashboard-app/server-prefetch");
const { sessionQuery } = await import("../dashboard-app/lib/session");
const { dashboardBillingQuery } = await import("../dashboard-app/queries/billing");
const { teamDetailQuery } = await import("../dashboard-app/queries/teams");

const request = new Request("https://cmux.test/dashboard/billing", { headers: { cookie: "session=1" } });

beforeEach(() => {
  sessionStatus = 200;
  calls.length = 0;
});

function hydrated(state: Parameters<typeof hydrate>[1]) {
  const client = new QueryClient();
  hydrate(client, state);
  return client;
}

describe("dashboard server prefetch", () => {
  test("a signed-out session stops before any route read", async () => {
    sessionStatus = 401;
    expect(await prefetchDashboard(request, "/dashboard/billing", {})).toEqual({ kind: "signedOut" });
    expect(calls).toEqual(["account.session"]);
  });

  test("fills the session and the route's reads under the SPA's query keys", async () => {
    const result = await prefetchDashboard(request, "/dashboard/billing", { team: "team-1" });
    if (result.kind !== "ready") throw new Error("expected ready");
    const client = hydrated(result.state);
    expect(client.getQueryData(sessionQuery.queryKey)).toEqual(session);
    expect(client.getQueryData(dashboardBillingQuery("team-1").queryKey)).toMatchObject({ selectedTeamId: "team-1" });
    expect(calls).toContain('account.billing:{"team":"team-1"}');
  });

  test("a refused route read is left for the SPA to fetch and render in place", async () => {
    const result = await prefetchDashboard(request, "/dashboard/teams/team-9/members", {});
    if (result.kind !== "ready") throw new Error("expected ready");
    expect(calls).toEqual(["account.session", "teams.detail"]);
    expect(hydrated(result.state).getQueryData(teamDetailQuery("team-9").queryKey)).toBeUndefined();
  });
});
