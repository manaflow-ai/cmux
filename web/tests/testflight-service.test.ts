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
  enrollTester,
  findBetaTesterByEmail,
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

  test("enrolls a new email in the Pro group and asks Apple to send the invitation", async () => {
    await enrollTester("New@Example.com", "New", "Tester");

    expect(ascFetch).toHaveBeenCalledTimes(2);
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

    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesterInvitations",
      expect.objectContaining({ method: "POST" }),
    );
    expect(JSON.parse(String(callInit(1).body))).toEqual({
      data: {
        type: "betaTesterInvitations",
        relationships: {
          app: { data: { type: "apps", id: "6757092429" } },
          betaTester: {
            data: { type: "betaTesters", id: "tester_new" },
          },
        },
      },
    });
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
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesterInvitations",
      expect.objectContaining({ method: "POST" }),
    );
  });

  test("double-enroll is a no-op when the group relationship already exists", async () => {
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
        ([path]) =>
          path === "/v1/betaTesterInvitations" ||
          String(path).includes("/relationships/betaTesters"),
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
