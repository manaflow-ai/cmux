import { describe, expect, test } from "bun:test";
import {
  createHiveState,
  getHivePairingSecret,
  hiveSnapshot,
  unlinkHiveNode,
  upsertHiveNode,
  upsertHivePairing,
} from "../services/hive/state";
import type { HiveNode } from "../services/hive/types";

describe("hive actor state", () => {
  test("upserts nodes and keeps online nodes first", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({ id: "linux", name: "Linux host", is_online: false }));
    upsertHiveNode(state, node({ id: "mac", name: "MacBook", is_online: true }));
    upsertHiveNode(state, node({ id: "linux", name: "Linux tower", is_online: true }));

    expect(hiveSnapshot(state).nodes.map((entry) => entry.id)).toEqual(["linux", "mac"]);
    expect(hiveSnapshot(state).nodes[0].name).toBe("Linux tower");
    expect(hiveSnapshot(state).workspaces).toEqual([]);
  });

  test("preserves previous workspaces while a revived node is still restoring", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      workspaces: [workspace("main"), workspace("docs")],
    }));

    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      restore_state: "restoring",
      snapshot_mode: "full_replace",
      node_started_at_unix: 200,
      workspaces: [],
    }));

    expect(hiveSnapshot(state).nodes[0].workspaces.map((entry) => entry.id)).toEqual([
      "docs",
      "main",
    ]);
  });

  test("allows the same revived node to replace stale workspaces once restore is ready", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      workspaces: [workspace("main"), workspace("docs")],
    }));

    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      restore_state: "ready",
      snapshot_mode: "full_replace",
      node_started_at_unix: 200,
      workspaces: [workspace("agent")],
    }));

    expect(hiveSnapshot(state).nodes[0].workspaces.map((entry) => entry.id)).toEqual(["agent"]);
  });

  test("removes workspaces only with explicit tombstones during incremental updates", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      workspaces: [workspace("main"), workspace("docs")],
    }));

    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      tombstone_workspace_ids: ["docs"],
      workspaces: [workspace("agent")],
    }));

    expect(hiveSnapshot(state).nodes[0].workspaces.map((entry) => entry.id)).toEqual([
      "agent",
      "main",
    ]);
  });

  test("marks nodes offline after their lease expires without deleting workspaces", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      lease_expires_at_unix: 200,
      workspaces: [workspace("main")],
    }));

    const snapshot = hiveSnapshot(state, 201);

    expect(snapshot.nodes[0].is_online).toBe(false);
    expect(snapshot.nodes[0].workspaces.map((entry) => entry.id)).toEqual(["main"]);
  });

  test("ignores stale publications from an older node session", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({
      id: "mac",
      name: "MacBook",
      is_online: true,
      node_started_at_unix: 200,
      workspaces: [workspace("current")],
    }));

    upsertHiveNode(state, node({
      id: "mac",
      name: "Old MacBook",
      is_online: false,
      node_started_at_unix: 100,
      restore_state: "ready",
      snapshot_mode: "full_replace",
      workspaces: [workspace("stale")],
    }));

    expect(hiveSnapshot(state).nodes[0].name).toBe("MacBook");
    expect(hiveSnapshot(state).nodes[0].workspaces.map((entry) => entry.id)).toEqual(["current"]);
  });

  test("unlinks an old node and its pairings only when explicitly requested", () => {
    const state = createHiveState();
    upsertHiveNode(state, node({ id: "mac", name: "MacBook", is_online: false }));
    upsertHivePairing(
      state,
      {
        pairing_id: "pairing-1",
        pairing_secret: "shared-secret-from-rivet",
        expires_at_unix: 200,
        node_id: "mac",
      },
      100,
    );

    expect(unlinkHiveNode(state, "mac")?.id).toBe("mac");
    expect(hiveSnapshot(state).nodes).toEqual([]);
    expect(getHivePairingSecret(state, "pairing-1", 150)).toBeNull();
  });

  test("stores pairing secrets behind summaries and expires lookups", () => {
    const state = createHiveState();
    const summary = upsertHivePairing(
      state,
      {
        pairing_id: "pairing-1",
        pairing_secret: "shared-secret-from-rivet",
        expires_at_unix: 200,
        node_id: "mac",
      },
      100,
    );

    expect(summary).toEqual({
      pairing_id: "pairing-1",
      expires_at_unix: 200,
      node_id: "mac",
    });
    expect(JSON.stringify(summary)).not.toContain("shared-secret-from-rivet");
    expect(getHivePairingSecret(state, "pairing-1", 199)).toEqual({
      pairing_id: "pairing-1",
      pairing_secret: "shared-secret-from-rivet",
      expires_at_unix: 200,
    });
    expect(getHivePairingSecret(state, "pairing-1", 200)).toBeNull();
  });

  test("prunes expired pairings when a new pairing is stored", () => {
    const state = createHiveState();
    upsertHivePairing(
      state,
      {
        pairing_id: "expired",
        pairing_secret: "expired-secret-value",
        expires_at_unix: 90,
      },
      10,
    );
    upsertHivePairing(
      state,
      {
        pairing_id: "fresh",
        pairing_secret: "fresh-secret-value",
        expires_at_unix: 400,
      },
      100,
    );

    expect(getHivePairingSecret(state, "expired", 100)).toBeNull();
    expect(getHivePairingSecret(state, "fresh", 100)?.pairing_secret).toBe("fresh-secret-value");
  });
});

function node(input: Pick<HiveNode, "id" | "name" | "is_online"> & Partial<HiveNode>): HiveNode {
  return {
    ...input,
    workspaces: input.workspaces ?? [],
  };
}

function workspace(id: string) {
  return {
    id,
    title: id,
    unread: false,
    pinned: false,
    spaces: [],
  };
}
