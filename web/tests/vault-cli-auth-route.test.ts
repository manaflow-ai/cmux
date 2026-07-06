import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async () => stackUser());
const cloudDb = mock(() => createFakeDb());

const ORIGINAL_ENV = {
  CMUX_VAULT_ENABLED: process.env.CMUX_VAULT_ENABLED,
  CMUX_VAULT_S3_BUCKET: process.env.CMUX_VAULT_S3_BUCKET,
};

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../db/client", () => ({
  cloudDb,
  closeCloudDbForTests: async () => {},
}));

const { POST } = await import("../app/api/vault/cli/auth/approve/route");

beforeEach(() => {
  process.env.CMUX_VAULT_S3_BUCKET = "test-bucket";
  process.env.CMUX_VAULT_ENABLED = "1";
  getUser.mockClear();
  getUser.mockResolvedValue(stackUser());
  cloudDb.mockClear();
});

afterEach(() => {
  restoreEnv();
});

describe("Vault CLI auth approve route", () => {
  test("rejects cross-site cookie mutations before reaching the DB", async () => {
    const response = await POST(approveRequest({
      origin: "https://evil.example",
      "sec-fetch-site": "cross-site",
      "content-type": "application/json",
    }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("rejects cookie mutations without an Origin before reaching the DB", async () => {
    const response = await POST(approveRequest({
      "sec-fetch-site": "same-origin",
      "content-type": "application/json",
    }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("rejects cookie mutations without JSON content before reaching the DB", async () => {
    const response = await POST(approveRequest({
      origin: "https://cmux.test",
      "content-type": "text/plain",
    }));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "forbidden" });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("allows same-origin JSON cookie mutations to reach the DB", async () => {
    const response = await POST(approveRequest({
      origin: "https://cmux.test",
      "content-type": "application/json",
    }));

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "auth_request_not_pending" });
    expect(cloudDb).toHaveBeenCalled();
  });

  test("allows native bearer mutations to bypass browser guards", async () => {
    const response = await POST(approveRequest({
      authorization: "Bearer x",
      "x-stack-refresh-token": "y",
      origin: "https://evil.example",
      "sec-fetch-site": "cross-site",
      "content-type": "application/json",
    }));

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "auth_request_not_pending" });
    expect(cloudDb).toHaveBeenCalled();
  });
});

function approveRequest(headers: HeadersInit): Request {
  return new Request("https://cmux.test/api/vault/cli/auth/approve", {
    method: "POST",
    headers,
    body: JSON.stringify({ userCode: "ABCD2345" }),
  });
}

function createFakeDb() {
  return {
    select: mock(() => ({
      from: mock(() => ({
        where: mock(() => ({
          orderBy: mock(() => ({
            limit: mock(async () => []),
          })),
        })),
      })),
    })),
  };
}

function stackUser() {
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "user@example.com",
    selectedTeam: {
      id: "team-1",
      displayName: "Team 1",
      clientReadOnlyMetadata: {},
    },
  };
}

function restoreEnv(): void {
  restoreEnvValue("CMUX_VAULT_ENABLED", ORIGINAL_ENV.CMUX_VAULT_ENABLED);
  restoreEnvValue("CMUX_VAULT_S3_BUCKET", ORIGINAL_ENV.CMUX_VAULT_S3_BUCKET);
}

function restoreEnvValue(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}
