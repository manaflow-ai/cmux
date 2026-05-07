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
const unlinkNode = mock(async (nodeID: string) => ({
  id: nodeID,
  name: "Old Mac",
  is_online: false,
  workspaces: [],
}));
const hiveStoreForTeam = mock(() => ({
  list,
  upsertNode,
  unlinkNode,
  upsertPairing,
  getPairingSecret,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("../services/hive/rivetClient", () => ({
  hiveStoreForTeam,
  hiveStoreForUser: mock((userID: string) => hiveStoreForTeam(`legacy-user:${userID}`)),
}));

const hiveRoute = await import("../app/api/hive/route");
const nodesRoute = await import("../app/api/hive/nodes/route");
const nodeRoute = await import("../app/api/hive/nodes/[id]/route");
const pairingsRoute = await import("../app/api/hive/pairings/route");
const secretRoute = await import("../app/api/hive/pairings/[id]/secret/route");
const teamsRoute = await import("../app/api/hive/teams/route");

beforeEach(() => {
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  hiveStoreForTeam.mockClear();
  list.mockClear();
  upsertNode.mockClear();
  unlinkNode.mockClear();
  upsertPairing.mockClear();
  getPairingSecret.mockClear();
});

describe("hive API", () => {
  test("rejects unauthenticated discovery before reaching Rivet", async () => {
    const response = await hiveRoute.GET(new Request("https://cmux.test/api/hive"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(hiveStoreForTeam).not.toHaveBeenCalled();
  });

  test("returns default personal-team hive discovery records", async () => {
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
    expect(hiveStoreForTeam).toHaveBeenCalledWith("personal:user-1");
  });

  test("uses the requested Stack team when the caller belongs to it", async () => {
    getUser.mockResolvedValue(authedStackUser({
      listTeams: async () => [
        { id: "team-alpha", displayName: "Alpha Team", slug: "alpha" },
      ],
    }));

    const response = await hiveRoute.GET(
      new Request("https://cmux.test/api/hive", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-team-id": "team-alpha",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(hiveStoreForTeam).toHaveBeenCalledWith("team-alpha");
  });

  test("defaults to personal Hive team even when Stack has a selected shared team", async () => {
    getUser.mockResolvedValue(authedStackUser({
      selectedTeam: { id: "team-alpha", displayName: "Alpha Team" },
      listTeams: async () => [{ id: "team-alpha", displayName: "Alpha Team" }],
    }));

    const response = await hiveRoute.GET(
      new Request("https://cmux.test/api/hive", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(hiveStoreForTeam).toHaveBeenCalledWith("personal:user-1");
  });

  test("uses the real Stack personal team id when Stack exposes one", async () => {
    getUser.mockResolvedValue(authedStackUser({
      selectedTeam: { id: "team-alpha", displayName: "Alpha Team" },
      listTeams: async () => [
        { id: "team-personal", displayName: "Personal", isPersonal: true },
        { id: "team-alpha", displayName: "Alpha Team" },
      ],
    }));

    const response = await hiveRoute.GET(
      new Request("https://cmux.test/api/hive", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(hiveStoreForTeam).toHaveBeenCalledWith("team-personal");
  });

  test("rejects requested Stack teams the caller cannot access", async () => {
    getUser.mockResolvedValue(authedStackUser({
      listTeams: async () => [{ id: "team-alpha", displayName: "Alpha Team" }],
    }));

    const response = await hiveRoute.GET(
      new Request("https://cmux.test/api/hive?teamId=team-beta", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "team not found" });
    expect(hiveStoreForTeam).not.toHaveBeenCalled();
  });

  test("lists available Hive teams for the settings picker", async () => {
    getUser.mockResolvedValue(authedStackUser({
      selectedTeam: {
        id: "team-personal",
        displayName: "Personal",
        isPersonal: true,
      },
      listTeams: async () => [
        { id: "team-personal", displayName: "Personal", isPersonal: true },
        { id: "team-alpha", displayName: "Alpha Team", slug: "alpha" },
      ],
    }));

    const response = await teamsRoute.GET(
      new Request("https://cmux.test/api/hive/teams", {
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      teams: [
        { id: "team-personal", display_name: "Personal", is_personal: true },
        { id: "team-alpha", display_name: "Alpha Team", is_personal: false },
      ],
      default_team_id: "team-personal",
      selected_team_id: "team-personal",
    });
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
    expect(hiveStoreForTeam).toHaveBeenCalledWith("personal:user-1");
  });

  test("unlinks old nodes behind Stack auth", async () => {
    getUser.mockResolvedValue(authedStackUser());

    const response = await nodeRoute.DELETE(
      new Request("https://cmux.test/api/hive/nodes/old-mac", {
        method: "DELETE",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
      }),
      { params: Promise.resolve({ id: "old-mac" }) },
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      node: {
        id: "old-mac",
        name: "Old Mac",
        is_online: false,
        workspaces: [],
      },
    });
    expect(unlinkNode).toHaveBeenCalledWith("old-mac");
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

function authedStackUser(overrides: Record<string, unknown> = {}) {
  return {
    id: "user-1",
    displayName: null,
    primaryEmail: "user@example.com",
    selectedTeam: null,
    listTeams: async () => [],
    ...overrides,
  };
}
