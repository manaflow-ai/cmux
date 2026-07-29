import { beforeEach, describe, expect, mock, test } from "bun:test";

class MockAscApiError extends Error {
  readonly name = "AscApiError";

  constructor(
    message: string,
    readonly status: number,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

const ascFetch = mock(async () => ({}));

mock.module("../services/asc/client", () => ({
  AscApiError: MockAscApiError,
  AscConfigurationError: class AscConfigurationError extends Error {},
  AscNetworkError: class AscNetworkError extends Error {},
  ascFetch,
  isAscConfigured: () => true,
}));

const {
  proTestflightEnrollmentEmails,
  recordProOwnedLegacyTestflightGroup,
  recordProTestflightEnrollmentEmail,
  enrollTester,
  findBetaTesterByEmail,
  proTestflightRemovalTargets,
  removeTester,
  testerGroupStatus,
} = await import("../services/asc/testflight");

describe("TestFlight ASC service", () => {
  beforeEach(() => {
    ascFetch.mockClear();
    mockImplementation(ascFetch, async (path: unknown, init?: unknown) => {
      if (path === "/v1/betaTesters" && (init as { method?: string })?.method === "POST") {
        return {
          data: {
            type: "betaTesters",
            id: "tester_new",
          },
        };
      }
      return {};
    });
  });

  test("enrolls a new email in the Pro group without resending the automatic invitation", async () => {
    await enrollTester("New@Example.com", "New", "Tester");

    expect(ascFetch).toHaveBeenCalledTimes(1);
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesters",
      expect.objectContaining({ method: "POST" }),
    );
    const body = JSON.parse(String(callInit(0).body));
    expect(body).toEqual({
      data: {
        type: "betaTesters",
        attributes: {
          email: "new@example.com",
          firstName: "New",
          lastName: "Tester",
        },
        relationships: {
          betaGroups: {
            data: [
              {
                type: "betaGroups",
                id: "34fbede5-3880-4560-b1bb-a45787249780",
              },
            ],
          },
        },
      },
    });

    expect(
      (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls.some(
        ([path]) => path === "/v1/betaTesterInvitations",
      ),
    ).toBe(false);
  });

  test("falls back to adding an existing tester to the group", async () => {
    mockImplementation(ascFetch, async (path: unknown, init?: unknown) => {
      if (path === "/v1/betaTesters" && (init as { method?: string })?.method === "POST") {
        throw new MockAscApiError("exists", 409);
      }
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_123");
      }
      if (String(path).includes("/betaGroups?")) {
        return { data: [] };
      }
      return {};
    });

    await enrollTester("exists@example.com");

    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaGroups/34fbede5-3880-4560-b1bb-a45787249780/relationships/betaTesters",
      expect.objectContaining({ method: "POST" }),
    );
    const body = JSON.parse(String(callInit(3).body));
    expect(body).toEqual({
      data: [{ type: "betaTesters", id: "tester_123" }],
    });
    expect(
      (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls.some(
        ([path]) => path === "/v1/betaTesterInvitations",
      ),
    ).toBe(false);
  });

  test("does not resend an invitation when group membership already exists", async () => {
    mockImplementation(ascFetch, async (path: unknown, init?: unknown) => {
      if (path === "/v1/betaTesters" && (init as { method?: string })?.method === "POST") {
        throw new MockAscApiError("exists", 409);
      }
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_123");
      }
      if (String(path).includes("/betaGroups?")) {
        return {
          data: [
            {
              type: "betaGroups",
              id: "34fbede5-3880-4560-b1bb-a45787249780",
            },
          ],
        };
      }
      return {};
    });

    await expect(enrollTester("exists@example.com")).resolves.toBeUndefined();
    expect(
      (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls.some(
        ([path]) => path === "/v1/betaTesterInvitations",
      ),
    ).toBe(false);
    expect(
      (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls.some(
        ([path]) => String(path).includes("/relationships/betaTesters"),
      ),
    ).toBe(false);
  });

  test("removes a tester from the configured group", async () => {
    mockImplementation(ascFetch, async (path: unknown) => {
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_123");
      }
      return {};
    });

    await removeTester("Leave@Example.com");

    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaGroups/34fbede5-3880-4560-b1bb-a45787249780/relationships/betaTesters",
      expect.objectContaining({ method: "DELETE" }),
    );
    const body = JSON.parse(String(callInit(1).body));
    expect(body).toEqual({
      data: [{ type: "betaTesters", id: "tester_123" }],
    });
  });

  test("removes a legacy Founder-group membership only from authoritative Pro ownership", async () => {
    mockImplementation(ascFetch, async (path: unknown) => {
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_legacy");
      }
      if (String(path).includes("/betaGroups?")) {
        return {
          data: [
            {
              type: "betaGroups",
              id: "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
            },
          ],
        };
      }
      return {};
    });

    await removeTester("legacy@example.com", {
      ownedLegacyGroupIDs: ["3ee84bfa-10ad-4f23-a45c-f9a3b037373e"],
    });

    const deletePaths = (ascFetch as unknown as { mock: { calls: unknown[][] } })
      .mock.calls
      .filter(([, init]) => (init as { method?: string } | undefined)?.method === "DELETE")
      .map(([path]) => String(path));
    expect(deletePaths).toEqual([
      "/v1/betaGroups/34fbede5-3880-4560-b1bb-a45787249780/relationships/betaTesters",
      "/v1/betaGroups/3ee84bfa-10ad-4f23-a45c-f9a3b037373e/relationships/betaTesters",
    ]);
  });

  test("never infers Founder ownership from overlapping Founder and Pro membership", async () => {
    mockImplementation(ascFetch, async (path: unknown) => {
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_founder_and_pro");
      }
      if (String(path).includes("/betaGroups?")) {
        return {
          data: [
            {
              type: "betaGroups",
              id: "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
            },
            {
              type: "betaGroups",
              id: "34fbede5-3880-4560-b1bb-a45787249780",
            },
          ],
        };
      }
      return {};
    });

    await removeTester("founder-and-pro@example.com", {
      ownedLegacyGroupIDs: [],
    });

    const deletePaths = (ascFetch as unknown as { mock: { calls: unknown[][] } })
      .mock.calls
      .filter(([, init]) => (init as { method?: string } | undefined)?.method === "DELETE")
      .map(([path]) => String(path));
    expect(deletePaths).toEqual([
      "/v1/betaGroups/34fbede5-3880-4560-b1bb-a45787249780/relationships/betaTesters",
    ]);
  });

  test("looks up tester group status", async () => {
    mockImplementation(ascFetch, async (path: unknown) => {
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_123", "INVITED");
      }
      return {
        data: [
          { type: "betaGroups", id: "other" },
          {
            type: "betaGroups",
            id: "34fbede5-3880-4560-b1bb-a45787249780",
          },
        ],
      };
    });

    await expect(testerGroupStatus("status@example.com")).resolves.toEqual({
      enrolled: true,
      state: "INVITED",
    });
  });

  test("does not treat Founder’s Edition membership as Pro enrollment", async () => {
    mockImplementation(ascFetch, async (path: unknown) => {
      if (String(path).startsWith("/v1/betaTesters?")) {
        return betaTesterList("tester_123", "ACCEPTED");
      }
      return {
        data: [
          {
            type: "betaGroups",
            id: "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
          },
        ],
      };
    });

    await expect(testerGroupStatus("founder@example.com")).resolves.toEqual({
      enrolled: false,
      state: "ACCEPTED",
    });
  });

  test("findBetaTesterByEmail returns null when ASC has no tester", async () => {
    mockImplementation(ascFetch, async () => ({ data: [] }));

    await expect(findBetaTesterByEmail("none@example.com")).resolves.toBeNull();
  });

  test("records legacy Pro ownership without replacing other Stack metadata", async () => {
    const update = mock(async () => undefined);
    const user = {
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        retained: { value: true },
      },
      update,
    };

    await expect(
      recordProOwnedLegacyTestflightGroup(user, "Legacy@Example.com"),
    ).resolves.toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        retained: { value: true },
        cmuxProTestflightOwnedLegacyGroupIDs: [
          "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
        ],
        cmuxProTestflightOwnedLegacyEmails: ["legacy@example.com"],
      },
    });
  });

  test("records every Pro enrollment email without replacing other Stack metadata", async () => {
    const update = mock(async () => undefined);
    const user = {
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        cmuxProTestflightEnrollmentEmails: ["first@example.com"],
      },
      update,
    };

    await expect(
      recordProTestflightEnrollmentEmail(user, "Second@Example.com"),
    ).resolves.toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        cmuxProTestflightEnrollmentEmails: [
          "first@example.com",
          "second@example.com",
        ],
      },
    });
    expect(proTestflightEnrollmentEmails({
      cmuxProTestflightEnrollmentEmails: ["First@Example.com", "first@example.com"],
    })).toEqual(["first@example.com"]);
  });

  test("legacy Pro ownership backfill is idempotent", async () => {
    const update = mock(async () => undefined);
    const user = {
      clientReadOnlyMetadata: {
        cmuxProTestflightOwnedLegacyGroupIDs: [
          "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
        ],
        cmuxProTestflightOwnedLegacyEmails: ["legacy@example.com"],
      },
      update,
    };

    await expect(
      recordProOwnedLegacyTestflightGroup(user, "legacy@example.com"),
    ).resolves.toBe(false);
    expect(update).not.toHaveBeenCalled();
  });

  test("targets the current Pro email and the exact legacy enrollment email", () => {
    expect(proTestflightRemovalTargets("Current@Example.com", {
      cmuxProTestflightEnrollmentEmails: ["Joined@Example.com"],
      cmuxProTestflightOwnedLegacyGroupIDs: [
        "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
      ],
      cmuxProTestflightOwnedLegacyEmails: ["Legacy@Example.com"],
    })).toEqual([
      {
        email: "current@example.com",
        ownedLegacyGroupIDs: [],
      },
      {
        email: "joined@example.com",
        ownedLegacyGroupIDs: [],
      },
      {
        email: "legacy@example.com",
        ownedLegacyGroupIDs: [
          "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
        ],
      },
    ]);
  });

  test("does not infer legacy Founder ownership from group metadata alone", () => {
    expect(proTestflightRemovalTargets("current@example.com", {
      cmuxProTestflightOwnedLegacyGroupIDs: [
        "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
      ],
    })).toEqual([{
      email: "current@example.com",
      ownedLegacyGroupIDs: [],
    }]);
  });

  test("removes a recorded legacy enrollment when the current email is absent", () => {
    expect(proTestflightRemovalTargets(null, {
      cmuxProTestflightOwnedLegacyGroupIDs: [
        "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
      ],
      cmuxProTestflightOwnedLegacyEmails: ["legacy@example.com"],
    })).toEqual([{
      email: "legacy@example.com",
      ownedLegacyGroupIDs: [
        "3ee84bfa-10ad-4f23-a45c-f9a3b037373e",
      ],
    }]);
  });
});

function betaTesterList(id: string, state?: string) {
  return {
    data: [
      {
        type: "betaTesters",
        id,
        attributes: state ? { state } : {},
      },
    ],
  };
}

function callInit(index: number): RequestInit {
  return (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls[index][1] as RequestInit;
}

function mockImplementation(
  fn: unknown,
  implementation: (...args: unknown[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}
