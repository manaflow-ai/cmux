import { describe, expect, it } from "bun:test";
import {
  VIEW_LEASE_MS,
  parseViewing,
  parseWorkspaceScope,
  renewViewer,
  viewerIdentity,
  workspaceRoom,
  workspaceViewers,
  type ViewerLease,
} from "../src/workspacePresence";
import type { AuthedUser } from "../src/auth";

const MAC_OWNER = "11111111-2222-4333-8444-555555555555";
const MAC_WORKSPACE = "99999999-2222-4333-8444-555555555555";

function user(overrides: Partial<AuthedUser> = {}): AuthedUser {
  return {
    id: "user-1",
    selectedTeamId: "team-1",
    teamIds: ["team-1"],
    ...overrides,
  };
}

function lease(overrides: Partial<ViewerLease> = {}): ViewerLease {
  return {
    identity: { id: "user-1" },
    expiresAt: 100_000,
    viewingUntil: 10_000,
    scope: { kind: "mac", ownerID: MAC_OWNER, instanceTag: "default", workspaceID: MAC_WORKSPACE },
    ...overrides,
  };
}

describe("workspace presence scope", () => {
  it("accepts a strict Mac scope and rejects cross-kind fields", () => {
    expect(parseWorkspaceScope({
      kind: "mac", ownerID: MAC_OWNER, instanceTag: "default", workspaceID: MAC_WORKSPACE,
    })).toEqual({
      kind: "mac", ownerID: MAC_OWNER, instanceTag: "default", workspaceID: MAC_WORKSPACE,
    });
    expect(parseWorkspaceScope({
      kind: "mac", ownerID: MAC_OWNER, instanceTag: "default", workspaceID: MAC_WORKSPACE, teamID: "team-1",
    })).toBeNull();
    expect(parseWorkspaceScope({ kind: "cloud", ownerID: "vm-1", workspaceID: "ws-1" })).toBeNull();
  });

  it("partitions Cloud rooms by verified team membership", () => {
    const scope = { kind: "cloud" as const, ownerID: "vm-1", workspaceID: "ws-1", teamID: "team-1" };
    expect(workspaceRoom(scope, user())).toContain("team-1");
    expect(workspaceRoom(scope, user({ id: "user-2", teamIds: ["team-2"] }))).toBeNull();
    expect(workspaceRoom({ ...scope, teamID: "user-1" }, user())).toContain("user-1");
  });
});

describe("workspace presence leases", () => {
  it("renews only active viewing and caps it at token expiry", () => {
    expect(renewViewer(lease({ expiresAt: 20_000 }), true, 1_000).viewingUntil).toBe(20_000);
    expect(renewViewer(lease(), false, 1_000).viewingUntil).toBe(0);
    expect(renewViewer(lease(), true, 1_000).viewingUntil).toBe(1_000 + VIEW_LEASE_MS);
  });

  it("coalesces multiple devices for one account and excludes expired views", () => {
    const viewers = workspaceViewers([
      lease({ identity: { id: "user-b" } }),
      lease({ identity: { id: "user-a" } }),
      lease({ identity: { id: "user-a", displayName: "newer" } }),
      lease({ identity: { id: "expired" }, viewingUntil: 1 }),
    ], 2_000);
    expect(viewers.map((value) => value.id)).toEqual(["user-a", "user-b"]);
    expect(viewers.find((value) => value.id === "user-a")?.displayName).toBe("newer");
  });

  it("accepts only the bounded view message", () => {
    expect(parseViewing('{"type":"view","active":true}')).toBe(true);
    expect(parseViewing('{"type":"view","active":false}')).toBe(false);
    expect(parseViewing('{"type":"view","active":true,"extra":1}')).toBeNull();
    expect(parseViewing(new ArrayBuffer(0))).toBeNull();
  });
});

describe("viewer identity", () => {
  it("keeps bounded Stack profile metadata and rejects non-HTTPS avatars", () => {
    const result = viewerIdentity(user({
      displayName: "  Ada\u0000 Lovelace  ",
      profileImageURL: "http://example.test/avatar.png",
    }));
    expect(result).toEqual({ id: "user-1", displayName: "Ada Lovelace" });
  });
});
