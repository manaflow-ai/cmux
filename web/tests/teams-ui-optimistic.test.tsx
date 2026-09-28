import { afterEach, describe, expect, test } from "bun:test";
import { MutationObserver, QueryClient } from "@tanstack/react-query";
import {
  changeRoleMutation,
  revokeInvitationMutation,
  revokeLinkMutation,
  type TeamDetail,
  TeamApiError,
  teamQueryKeys,
} from "../dashboard-app/queries/teams";
import { teamDetailFixture } from "./helpers/teams-ui-fixtures";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

type Deferred = { resolve: (response: Response) => void; request: Promise<Request> };

/** A fetch whose single response the test releases after inspecting the optimistic cache. */
function deferredFetch(): Deferred {
  let resolve!: (response: Response) => void;
  let captured!: (request: Request) => void;
  const request = new Promise<Request>((done) => {
    captured = done;
  });
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    captured(new Request(new URL(String(input), "https://cmux.test"), init));
    return new Promise<Response>((done) => {
      resolve = done;
    });
  }) as typeof fetch;
  return { resolve: (response) => resolve(response), request };
}

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const key = teamQueryKeys.detail("team-1");
  queryClient.setQueryData(key, teamDetailFixture());
  // Keep the refetch after settle from hitting the network.
  queryClient.setQueryDefaults(key, { queryFn: () => queryClient.getQueryData(key) as TeamDetail });
  const detail = () => queryClient.getQueryData<TeamDetail>(key);
  return { queryClient, detail };
}

function errorResponse(status: number, code: string) {
  return new Response(JSON.stringify({ error: { code, message: "refused" } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("optimistic team mutations", () => {
  test("revoking an invitation removes it at once and restores it when the server refuses", async () => {
    const { queryClient, detail } = setup();
    const network = deferredFetch();
    const observer = new MutationObserver(queryClient, revokeInvitationMutation(queryClient, "team-1"));

    const result = observer.mutate("inv-1").catch((error: unknown) => error);
    const request = await network.request;
    expect(request.method).toBe("DELETE");
    expect(new URL(request.url).pathname).toBe("/api/teams/team-1/invitations/inv-1");
    expect(detail()?.invitations.map((invitation) => invitation.id)).toEqual(["inv-2"]);

    network.resolve(errorResponse(404, "invitation_not_found"));
    const error = await result;
    expect(error).toBeInstanceOf(TeamApiError);
    expect((error as TeamApiError).code).toBe("invitation_not_found");
    expect(detail()?.invitations.map((invitation) => invitation.id)).toEqual(["inv-1", "inv-2"]);
  });

  test("a successful revoke keeps the row removed", async () => {
    const { queryClient, detail } = setup();
    const network = deferredFetch();
    const observer = new MutationObserver(queryClient, revokeLinkMutation(queryClient, "team-1"));

    const result = observer.mutate("link-1");
    await network.request;
    expect(detail()?.links).toEqual([]);
    network.resolve(new Response(null, { status: 204 }));
    await result;
    expect(detail()?.links).toEqual([]);
  });

  test("a last-admin refusal reverts an optimistic demotion", async () => {
    const { queryClient, detail } = setup();
    const network = deferredFetch();
    const observer = new MutationObserver(queryClient, changeRoleMutation(queryClient, "team-1"));

    const result = observer.mutate({ userId: "user-1", role: "member" }).catch((error: unknown) => error);
    const request = await network.request;
    expect(await request.json()).toEqual({ role: "member" });
    expect(detail()?.members.find((member) => member.userId === "user-1")?.role).toBe("member");

    network.resolve(errorResponse(409, "last_admin"));
    expect(((await result) as TeamApiError).code).toBe("last_admin");
    expect(detail()?.members.find((member) => member.userId === "user-1")?.role).toBe("admin");
  });
});
