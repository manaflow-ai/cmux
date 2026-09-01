import { beforeEach, describe, expect, mock, test } from "bun:test";

import {
  clearTeamSeatCacheForTests,
  resolveTeamSeatEntitlement,
} from "../services/billing/teamSeats";

describe("Team subscription seat enforcement", () => {
  beforeEach(() => {
    clearTeamSeatCacheForTests();
  });

  test("keeps every member entitled below the subscription seat count", async () => {
    const listUsers = mock(async () => [
      { id: "member-a" },
      { id: "member-b" },
    ]);
    const getTeam = mock(async () => ({ listUsers }));
    const loadSubscription = mock(async () => ({ active: true, seats: 3 }));

    const decision = await resolveTeamSeatEntitlement(
      "team-under-limit",
      "member-b",
      { stackApp: { getTeam }, loadSubscription, cache: false },
    );

    expect(decision).toEqual({
      status: "active",
      entitled: true,
      seatCount: 3,
      memberCount: 2,
      memberListingAvailable: true,
    });
    expect(loadSubscription).toHaveBeenCalledWith("team-under-limit");
    expect(getTeam).toHaveBeenCalledWith("team-under-limit");
    expect(listUsers).toHaveBeenCalledTimes(1);
  });

  test("demotes members beyond the limit with a deterministic member-id tiebreak", async () => {
    const getTeam = async () => ({
      // Stack's team-user response does not promise membership creation time.
      // The resolver therefore keeps the lexicographically oldest id.
      listUsers: async () => [
        { id: "member-b", signedUpAt: new Date("2020-01-01") },
        { id: "member-a", signedUpAt: new Date("2025-01-01") },
      ],
    });
    const options = {
      stackApp: { getTeam },
      loadSubscription: async () => ({ active: true, seats: 1 }),
      cache: false,
    };

    const included = await resolveTeamSeatEntitlement(
      "team-at-limit",
      "member-a",
      options,
    );
    const overLimit = await resolveTeamSeatEntitlement(
      "team-at-limit",
      "member-b",
      options,
    );

    expect(included.entitled).toBe(true);
    expect(overLimit).toMatchObject({
      status: "active",
      entitled: false,
      seatCount: 1,
      memberCount: 2,
    });
  });

  test("uses the seat quantity from the subscription loader", async () => {
    const loadSubscription = mock(async () => ({ active: true, seats: 2 }));
    const stackApp = {
      getTeam: async () => ({
        listUsers: async () => [
          { id: "member-a" },
          { id: "member-b" },
          { id: "member-c" },
        ],
      }),
    };

    const decision = await resolveTeamSeatEntitlement(
      "team-subscription-seats",
      "member-c",
      { stackApp, loadSubscription, cache: false },
    );

    expect(loadSubscription).toHaveBeenCalledWith("team-subscription-seats");
    expect(decision.seatCount).toBe(2);
    expect(decision.entitled).toBe(false);
  });

  test("shares one bounded subscription and roster lookup for concurrent checks", async () => {
    const loadSubscription = mock(async () => ({ active: true, seats: 2 }));
    const listUsers = mock(async () => [
      { id: "member-a" },
      { id: "member-b" },
    ]);
    const getTeam = mock(async () => ({ listUsers }));

    const [first, second] = await Promise.all([
      resolveTeamSeatEntitlement("team-cached", "member-a", {
        stackApp: { getTeam },
        loadSubscription,
      }),
      resolveTeamSeatEntitlement("team-cached", "member-b", {
        stackApp: { getTeam },
        loadSubscription,
      }),
    ]);

    expect(first.entitled).toBe(true);
    expect(second.entitled).toBe(true);
    expect(loadSubscription).toHaveBeenCalledTimes(1);
    expect(getTeam).toHaveBeenCalledTimes(1);
    expect(listUsers).toHaveBeenCalledTimes(1);
  });
});
