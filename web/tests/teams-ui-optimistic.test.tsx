import { afterEach, describe, expect, test } from "bun:test";
import { MutationObserver, QueryClient } from "@tanstack/react-query";
import {
  changeRoleMutation,
  revokeInvitationMutation,
  revokeLinkMutation,
  type TeamDetail,
  teamErrorCode,
  teamQueryKeys,
} from "../dashboard-app/queries/teams";
import { deferredProcedure } from "./helpers/fake-dashboard-rpc";
import { teamDetailFixture } from "./helpers/teams-ui-fixtures";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const key = teamQueryKeys.detail("team-1");
  queryClient.setQueryData(key, teamDetailFixture());
  // Keep the refetch after settle from hitting the network.
  queryClient.setQueryDefaults(key, { queryFn: () => queryClient.getQueryData(key) as TeamDetail });
  const detail = () => queryClient.getQueryData<TeamDetail>(key);
  return { queryClient, detail };
}

describe("optimistic team mutations", () => {
  test("revoking an invitation removes it at once and restores it when the server refuses", async () => {
    const { queryClient, detail } = setup();
    const network = deferredProcedure("teams.revokeInvitation");
    const observer = new MutationObserver(queryClient, revokeInvitationMutation(queryClient, "team-1"));

    const result = observer.mutate("inv-1").catch((error: unknown) => error);
    expect(await network.input).toEqual({ teamId: "team-1", invitationId: "inv-1" });
    expect(detail()?.invitations.map((invitation) => invitation.id)).toEqual(["inv-2"]);

    network.refuse(404, "invitation_not_found");
    expect(teamErrorCode(await result)).toBe("invitation_not_found");
    expect(detail()?.invitations.map((invitation) => invitation.id)).toEqual(["inv-1", "inv-2"]);
  });

  test("a successful revoke keeps the row removed", async () => {
    const { queryClient, detail } = setup();
    const network = deferredProcedure("teams.revokeLink");
    const observer = new MutationObserver(queryClient, revokeLinkMutation(queryClient, "team-1"));

    const result = observer.mutate("link-1");
    expect(await network.input).toEqual({ teamId: "team-1", linkId: "link-1" });
    expect(detail()?.links).toEqual([]);
    network.succeed({ ok: true });
    await result;
    expect(detail()?.links).toEqual([]);
  });

  test("a last-admin refusal reverts an optimistic demotion", async () => {
    const { queryClient, detail } = setup();
    const network = deferredProcedure("teams.changeRole");
    const observer = new MutationObserver(queryClient, changeRoleMutation(queryClient, "team-1"));

    const result = observer.mutate({ userId: "user-1", role: "member" }).catch((error: unknown) => error);
    expect(await network.input).toEqual({ teamId: "team-1", userId: "user-1", role: "member" });
    expect(detail()?.members.find((member) => member.userId === "user-1")?.role).toBe("member");

    network.refuse(409, "last_admin");
    expect(teamErrorCode(await result)).toBe("last_admin");
    expect(detail()?.members.find((member) => member.userId === "user-1")?.role).toBe("admin");
  });
});
