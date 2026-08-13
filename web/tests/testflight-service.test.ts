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
  FOUNDER_TESTFLIGHT_GROUP_ID,
  PRO_TESTFLIGHT_GROUP_ID,
  proTestflightEnrollmentEmails,
  proTestflightGrants,
  recordProOwnedLegacyTestflightGroup,
  recordProTestflightEnrollmentEmail,
  enrollTester,
  findBetaTesterByEmail,
  proTestflightRemovalTargets,
  removeTester,
  removeProTesterAccess,
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
                id: PRO_TESTFLIGHT_GROUP_ID,
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
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
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
              id: PRO_TESTFLIGHT_GROUP_ID,
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
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
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
              id: FOUNDER_TESTFLIGHT_GROUP_ID,
            },
          ],
        };
      }
      return {};
    });

    await removeTester("legacy@example.com", {
      ownedLegacyGroupIDs: [FOUNDER_TESTFLIGHT_GROUP_ID],
    });

    const deletePaths = (ascFetch as unknown as { mock: { calls: unknown[][] } })
      .mock.calls
      .filter(([, init]) => (init as { method?: string } | undefined)?.method === "DELETE")
      .map(([path]) => String(path));
    expect(deletePaths).toEqual([
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
      `/v1/betaGroups/${FOUNDER_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
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
              id: FOUNDER_TESTFLIGHT_GROUP_ID,
            },
            {
              type: "betaGroups",
              id: PRO_TESTFLIGHT_GROUP_ID,
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
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
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
            id: PRO_TESTFLIGHT_GROUP_ID,
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
            id: FOUNDER_TESTFLIGHT_GROUP_ID,
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
      recordProOwnedLegacyTestflightGroup(
        user,
        "Legacy@Example.com",
        { refresh: async () => undefined },
      ),
    ).resolves.toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        retained: { value: true },
        cmuxProTestflightOwnedLegacyGroupIDs: [
          FOUNDER_TESTFLIGHT_GROUP_ID,
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
      recordProTestflightEnrollmentEmail(
        user,
        "Second@Example.com",
        { refresh: async () => undefined },
      ),
    ).resolves.toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        cmuxProTestflightEnrollmentEmails: [
          "first@example.com",
          "second@example.com",
        ],
        cmuxProTestflightGrants: [
          { email: "first@example.com", source: "user" },
          { email: "second@example.com", source: "user" },
        ],
      },
    });
    expect(proTestflightEnrollmentEmails({
      cmuxProTestflightEnrollmentEmails: ["First@Example.com", "first@example.com"],
    })).toEqual(["first@example.com"]);
    expect(proTestflightGrants({
      cmuxProTestflightGrants: [
        { email: "First@Example.com", source: "user" },
        { email: "first@example.com", source: "user" },
      ],
    })).toEqual([{ email: "first@example.com", source: "user" }]);
  });

  test("retires each historical enrollment email after successful ASC removal", async () => {
    const remover = mock(async () => undefined);
    const updates: unknown[] = [];
    const metadata = {
      retained: true,
      cmuxProTestflightEnrollmentEmails: ["old@example.com"],
      cmuxProTestflightGrants: [
        { email: "old@example.com", source: "user" },
      ],
    };

    await (removeProTesterAccess as unknown as (
      currentEmail: string | null,
      metadata: unknown,
      remover: typeof removeTester,
      options: { updateMetadata: (next: unknown) => Promise<void> },
    ) => Promise<number>)(null, metadata, remover, {
      updateMetadata: async (next) => {
        updates.push(next);
      },
    });

    expect(remover).toHaveBeenCalledTimes(1);
    expect(updates).toEqual([{ retained: true }]);

    remover.mockClear();
    await removeProTesterAccess(null, updates.at(-1), remover);
    expect(remover).not.toHaveBeenCalled();
  });

  test("retires a grant-ledger email even when legacy enrollment metadata is absent", async () => {
    const removedEmails: string[] = [];
    const remover = async (email: string): Promise<void> => {
      removedEmails.push(email);
    };
    const updates: unknown[] = [];

    await (removeProTesterAccess as unknown as (
      currentEmail: string | null,
      metadata: unknown,
      remover: typeof removeTester,
      options: { updateMetadata: (next: unknown) => Promise<void> },
    ) => Promise<number>)(null, {
      retained: true,
      cmuxProTestflightGrants: [
        { email: "grant@example.com", source: "user" },
      ],
    }, remover, {
      updateMetadata: async (next) => {
        updates.push(next);
      },
    });

    expect(removedEmails).toEqual(["grant@example.com"]);
    expect(updates).toEqual([{ retained: true }]);
  });

  test("legacy Pro ownership backfill is idempotent", async () => {
    const update = mock(async () => undefined);
    const user = {
      clientReadOnlyMetadata: {
        cmuxProTestflightOwnedLegacyGroupIDs: [
          FOUNDER_TESTFLIGHT_GROUP_ID,
        ],
        cmuxProTestflightOwnedLegacyEmails: ["legacy@example.com"],
      },
      update,
    };

    await expect(
      recordProOwnedLegacyTestflightGroup(
        user,
        "legacy@example.com",
        { refresh: async () => undefined },
      ),
    ).resolves.toBe(false);
    expect(update).not.toHaveBeenCalled();
  });

  test("targets the current Pro email and the exact legacy enrollment email", () => {
    expect(proTestflightRemovalTargets("Current@Example.com", {
      cmuxProTestflightEnrollmentEmails: ["Joined@Example.com"],
      cmuxProTestflightOwnedLegacyGroupIDs: [
        FOUNDER_TESTFLIGHT_GROUP_ID,
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
          FOUNDER_TESTFLIGHT_GROUP_ID,
        ],
      },
    ]);
  });

  test("does not infer legacy Founder ownership from group metadata alone", () => {
    expect(proTestflightRemovalTargets("current@example.com", {
      cmuxProTestflightOwnedLegacyGroupIDs: [
        FOUNDER_TESTFLIGHT_GROUP_ID,
      ],
    })).toEqual([{
      email: "current@example.com",
      ownedLegacyGroupIDs: [],
    }]);
  });

  test("removes a recorded legacy enrollment when the current email is absent", () => {
    expect(proTestflightRemovalTargets(null, {
      cmuxProTestflightOwnedLegacyGroupIDs: [
        FOUNDER_TESTFLIGHT_GROUP_ID,
      ],
      cmuxProTestflightOwnedLegacyEmails: ["legacy@example.com"],
    })).toEqual([{
      email: "legacy@example.com",
      ownedLegacyGroupIDs: [
        FOUNDER_TESTFLIGHT_GROUP_ID,
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
