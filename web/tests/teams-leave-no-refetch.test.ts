import { describe, expect, test } from "bun:test";
import { QueryClient, QueryObserver } from "@tanstack/react-query";
import { leaveTeamMutation, teamMutationScope, teamQueryKeys } from "../dashboard-app/queries/teams";

// Regression: leaving a team reused remove-member, whose onSettled refetched
// the team detail while the team screen was still mounted, so the server
// answered 403 for a team the viewer had just left.
describe("leave team", () => {
  test("leaving does not refetch the team the viewer just left", async () => {
    const client = new QueryClient();
    let fetches = 0;
    const observer = new QueryObserver(client, {
      queryKey: teamQueryKeys.detail("team-a"),
      queryFn: async () => { fetches += 1; return {}; },
      staleTime: Infinity,
    });
    const unsubscribe = observer.subscribe(() => {});
    await observer.refetch();
    const before = fetches;
    const leave = client.getMutationCache().build(client, { ...leaveTeamMutation(client, "team-a"), mutationFn: async () => undefined });
    await leave.execute("viewer");
    await Promise.resolve();
    expect(fetches).toBe(before);
    expect(leaveTeamMutation(client, "team-a").scope).toEqual(teamMutationScope("team-a"));
    unsubscribe();
  });
});
