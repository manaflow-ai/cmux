import { describe, expect, mock, test } from "bun:test";

import { resolveBillingTeam } from "../services/billing/teamResolution";

describe("billing team resolution", () => {
  test("selectedTeam wins without listing teams", async () => {
    const listTeams = mock(async () => [
      paidTeam("team-paid"),
    ]);

    await expect(resolveBillingTeam({
      selectedTeam: freeTeam("team-selected"),
      listTeams,
    })).resolves.toMatchObject({ id: "team-selected" });
    expect(listTeams).not.toHaveBeenCalled();
  });

  test("uses the single listed team", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [freeTeam("team-only")],
    })).resolves.toMatchObject({ id: "team-only" });
  });

  test("returns null for multiple teams with no paid metadata", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        freeTeam("team-free"),
        { id: "team-empty", clientReadOnlyMetadata: { cmuxPlan: "" } },
      ],
    })).resolves.toBeNull();
  });

  test("preserves raw cmuxVmPlan masking before checking cmuxPlan", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        freeTeam("team-free"),
        { id: "team-masked", clientReadOnlyMetadata: { cmuxVmPlan: "", cmuxPlan: "team" } },
      ],
    })).resolves.toBeNull();
  });

  test("uses the only team paid through cmuxPlan", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        freeTeam("team-free"),
        { id: "team-paid", clientReadOnlyMetadata: { cmuxPlan: "team" } },
      ],
    })).resolves.toMatchObject({ id: "team-paid" });
  });

  test("uses the only team paid through cmuxVmPlan", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        freeTeam("team-free"),
        { id: "team-override", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
      ],
    })).resolves.toMatchObject({ id: "team-override" });
  });

  test("prefers a real cmuxPlan subscription over a cmuxVmPlan override even with a larger id", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-z", clientReadOnlyMetadata: { cmuxPlan: "team" } },
        { id: "team-a", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
      ],
    })).resolves.toMatchObject({ id: "team-z" });
  });

  test("picks the first team id deterministically when multiple teams have real subscriptions", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-z", clientReadOnlyMetadata: { cmuxPlan: "team" } },
        { id: "team-a", clientReadOnlyMetadata: { cmuxPlan: "team" } },
      ],
    })).resolves.toMatchObject({ id: "team-a" });
  });

  test("falls back to a cmuxVmPlan override team deterministically when no team has a real subscription", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [
        { id: "team-z", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } },
        { id: "team-a", clientReadOnlyMetadata: { cmuxVmPlan: "enterprise" } },
      ],
    })).resolves.toMatchObject({ id: "team-a" });
  });

  test("returns null for zero teams", async () => {
    await expect(resolveBillingTeam({
      selectedTeam: null,
      listTeams: async () => [],
    })).resolves.toBeNull();
  });
});

function paidTeam(id: string) {
  return { id, clientReadOnlyMetadata: { cmuxPlan: "team" } };
}

function freeTeam(id: string) {
  return { id, clientReadOnlyMetadata: { cmuxPlan: "free" } };
}
