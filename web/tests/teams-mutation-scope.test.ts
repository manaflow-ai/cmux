import { describe, expect, test } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import {
  changeRoleMutation,
  removeMemberMutation,
  resendInvitationMutation,
  revokeInvitationMutation,
  revokeLinkMutation,
  teamMutationScope,
  updateTeamMutation,
} from "../dashboard-app/queries/teams";

// Regression: deleting a team right after an optimistic edit let the edit's
// onSettled refetch the deleted team. One scope per team serializes them.
describe("team mutation scope", () => {
  test("every write to a team runs in that team's scope", () => {
    const client = new QueryClient();
    const factories = [
      changeRoleMutation,
      removeMemberMutation,
      resendInvitationMutation,
      revokeInvitationMutation,
      revokeLinkMutation,
      updateTeamMutation,
    ];
    for (const factory of factories) {
      expect(factory(client, "team-a").scope).toEqual(teamMutationScope("team-a"));
    }
    expect(teamMutationScope("team-a")).not.toEqual(teamMutationScope("team-b"));
  });

  test("a scoped delete waits for an earlier edit to settle", async () => {
    const client = new QueryClient();
    const order: string[] = [];
    let finishEdit!: () => void;
    const edit = client.getMutationCache().build(client, {
      scope: teamMutationScope("team-a"),
      mutationFn: () => new Promise<void>((resolve) => { finishEdit = resolve; }),
      onSettled: async () => { order.push("edit settled"); },
    });
    const remove = client.getMutationCache().build(client, {
      scope: teamMutationScope("team-a"),
      mutationFn: async () => { order.push("delete ran"); },
    });
    const editDone = edit.execute(undefined);
    const removeDone = remove.execute(undefined);
    await Promise.resolve();
    expect(order).toEqual([]);
    finishEdit();
    await Promise.all([editDone, removeDone]);
    expect(order).toEqual(["edit settled", "delete ran"]);
  });
});
