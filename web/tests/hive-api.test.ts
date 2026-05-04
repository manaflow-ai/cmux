import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { HiveNode, HivePairingInput } from "../services/hive/types";

const getUser = mock(async () => null);
const list = mock(async () => ({
  nodes: [
    {
      id: "macbook-lawrence",
      name: "Lawrence MacBook Pro",
      subtitle: "online over iroh",
      kind: "macos",
      is_online: true,
      workspaces: [
        {
          id: "workspace-main",
          title: "main",
          preview: "lawrence in ~/fun/cmux-cli",
          unread: false,
          pinned: true,
          spaces: [
            {
              id: "space-dev",
              title: "dev",
              terminals: [
                {
                  id: "terminal-shell",
                  title: "shell",
                  cols: 120,
                  rows: 40,
                  output_rows: ["lawrence in ~/fun/cmux-cli"],
                },
              ],
            },
          ],
        },
      ],
    },
  ],
  workspaces: [],
}));
const upsertNode = mock(async (node: HiveNode) => node);
const upsertPairing = mock(async (pairing: HivePairingInput) => ({
  pairing_id: pairing.pairing_id,
  expires_at_unix: pairing.expires_at_unix,
  node_id: pairing.node?.id ?? pairing.node_id ?? null,
}));
const getPairingSecret = mock(async (pairingID: string) => ({
  pairing_id: pairingID,
  pairing_secret: "shared-secret-from-rivet",
  expires_at_unix: 4_000_000_000,
}));
const hiveStoreForUser = mock(() => ({
  list,
  upsertNode,
  upsertPairing,
  getPairingSecret,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("../services/hive/rivetClient", () => ({
  hiveStoreForUser,
}));

const hiveRoute = await import("../app/api/hive/route");
const nodesRoute = await import("../app/api/hive/nodes/route");
const pairingsRoute = await import("../app/api/hive/pairings/route");
const secretRoute = await import("../app/api/hive/pairings/[id]/secret/route");

beforeEach(() => {
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  hiveStoreForUser.mockClear();
  list.mockClear();
  upsertNode.mockClear();
  upsertPairing.mockClear();
  getPairingSecret.mockClear();
});

describe("hive API", () => {
  test("rejects unauthenticated discovery before reaching Rivet", async () => {
    const response = await hiveRoute.GET(new Request("https://cmux.test/api/hive"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(hiveStoreForUser).not.toHaveBeenCalled();
  });

  test("returns Stack-scoped hive discovery records", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await hiveRoute.GET(
      new Request("https://cmux.test/api/hive", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(await list());
    expect(hiveStoreForUser).toHaveBeenCalledWith("user-1");
  });

  test("stores node metadata behind Stack auth", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const body = {
      id: "mac-mini-1",
      name: "Mac mini",
      kind: "macos",
      is_online: true,
      workspaces: [],
    };

    const response = await nodesRoute.POST(
      new Request("https://cmux.test/api/hive/nodes", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify(body),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ node: body });
    expect(upsertNode).toHaveBeenCalledWith(body);
  });

  test("stores pairing secrets without returning secret material", async () => {
    getUser.mockResolvedValue(authedStackUser());
    const body = {
      pairing_id: "pairing-1",
      pairing_secret: "shared-secret-from-rivet",
      expires_at_unix: 4_000_000_000,
      node: {
        id: "macbook-lawrence",
        name: "Lawrence MacBook Pro",
        kind: "macos",
        is_online: true,
        workspaces: [],
      },
    };

    const response = await pairingsRoute.POST(
      new Request("https://cmux.test/api/hive/pairings", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify(body),
      }),
    );

    expect(response.status).toBe(200);
    const payload = await response.json();
    expect(payload).toEqual({
      pairing: {
        pairing_id: "pairing-1",
        expires_at_unix: 4_000_000_000,
        node_id: "macbook-lawrence",
      },
    });
    expect(JSON.stringify(payload)).not.toContain("shared-secret-from-rivet");
  });

  test("returns pairing secret only after Stack auth", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await secretRoute.GET(
      new Request("https://cmux.test/api/hive/pairings/pairing-1/secret", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
      { params: Promise.resolve({ id: "pairing-1" }) },
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      pairing_id: "pairing-1",
      pairing_secret: "shared-secret-from-rivet",
      expires_at_unix: 4_000_000_000,
    });
    expect(getPairingSecret).toHaveBeenCalledWith("pairing-1");
  });

  test("rejects malformed pairing bodies before reaching Rivet", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await pairingsRoute.POST(
      new Request("https://cmux.test/api/hive/pairings", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          pairing_id: "",
          pairing_secret: "short",
          expires_at_unix: 0,
        }),
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "invalid hive pairing" });
    expect(upsertPairing).not.toHaveBeenCalled();
  });
});

function authedStackUser() {
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "user@example.com",
    selectedTeam: null,
    listTeams: async () => [],
  };
}
