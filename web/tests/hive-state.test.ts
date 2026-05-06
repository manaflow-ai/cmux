import { describe, expect, test } from "bun:test";
import {
  createHiveState,
  getHivePairingSecret,
  hiveSnapshot,
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

function node(input: Pick<HiveNode, "id" | "name" | "is_online">): HiveNode {
  return {
    ...input,
    workspaces: [],
  };
}

