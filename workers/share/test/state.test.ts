import { describe, expect, test } from "bun:test";
import {
  MAX_PENDING_VIEWERS,
  MAX_VIEWERS,
  canCreateViewer,
  colorForUser,
  decideViewer,
  hostAvailabilityExpired,
  hostReconnectDeadline,
  nextRoomAlarm,
  pendingViewerTicketIsFresh,
  viewerConnectionExpiry,
  normalizeShareId,
  type ViewerState,
  type ShareRoomMetadata,
} from "../src/state";

function viewer(index: number, access: ViewerState["access"]): ViewerState {
  return {
    userId: `user-${index}`,
    email: `person-${index}@example.com`,
    displayName: `Person ${index}`,
    color: colorForUser(`user-${index}`),
    access,
    requestedAt: 1_700_000_000_000 + index,
  };
}

describe("share room state", () => {
  test("accepts only 128-bit unpadded base64url share locators", () => {
    expect(normalizeShareId("AbCdEfGhIjKlMnOpQrSt_-")).toBe("AbCdEfGhIjKlMnOpQrSt_-");
    expect(normalizeShareId("too-short")).toBeNull();
    expect(normalizeShareId("AbCdEfGhIjKlMnOpQrSt+/" )).toBeNull();
  });

  test("pending viewers must refresh Stack authentication before late approval", () => {
    expect(viewerConnectionExpiry("pending", 10_000, 2_000)).toBe(2_000);
    expect(viewerConnectionExpiry("approved", 10_000, 2_000)).toBe(10_000);
    expect(pendingViewerTicketIsFresh(2_001, 2_000)).toBe(true);
    expect(pendingViewerTicketIsFresh(2_000, 2_000)).toBe(false);
    expect(pendingViewerTicketIsFresh(undefined, 2_000)).toBe(false);
  });

  test("assigns a stable accessible palette index per user", () => {
    expect(colorForUser("user-123")).toBe(colorForUser("user-123"));
    expect(colorForUser("user-123")).toBeGreaterThanOrEqual(0);
    expect(colorForUser("user-123")).toBeLessThan(12);
  });

  test("owner decisions are idempotent", () => {
    const pending = viewer(1, "pending");
    const approved = decideViewer(pending, "allow", 2_000);
    expect(approved.access).toBe("approved");
    expect(approved.decidedAt).toBe(2_000);
    expect(decideViewer(approved, "deny", 3_000)).toBe(approved);
  });

  test("bounds the combined approved and pending viewer population", () => {
    expect(canCreateViewer(Array.from({ length: MAX_VIEWERS }, (_, index) => viewer(index, "approved"))))
      .toBe("room_full");
    expect(canCreateViewer(Array.from({ length: MAX_PENDING_VIEWERS }, (_, index) => viewer(index, "pending"))))
      .toBe("too_many_pending");
    expect(canCreateViewer([
      ...Array.from({ length: MAX_VIEWERS - 1 }, (_, index) => viewer(index, "approved")),
      viewer(MAX_VIEWERS, "pending"),
    ])).toBe("room_full");
    expect(canCreateViewer([viewer(1, "pending")])).toBe("ok");
  });

  test("bounds host reconnect grace by the room expiry", () => {
    const metadata: ShareRoomMetadata = {
      shareId: "AbCdEfGhIjKlMnOpQrSt_-",
      owner: { userId: "owner", email: "owner@example.com", displayName: "Owner" },
      hostCapabilityHash: "hash",
      workspaceId: "workspace",
      workspaceTitle: "Workspace",
      createdAt: 1_000,
      expiresAt: 200_000,
      status: "active",
      hostConnectedAt: 50_000,
      hostDisconnectedAt: 100_000,
    };
    expect(hostReconnectDeadline(metadata)).toBe(200_000);
    expect(hostReconnectDeadline({ ...metadata, expiresAt: 500_000 })).toBe(220_000);
  });

  test("ends rooms that never establish their first host socket", () => {
    const metadata: ShareRoomMetadata = {
      shareId: "AbCdEfGhIjKlMnOpQrSt_-",
      owner: { userId: "owner", email: "owner@example.com", displayName: "Owner" },
      hostCapabilityHash: "hash",
      workspaceId: "workspace",
      workspaceTitle: "Workspace",
      createdAt: 1_000,
      expiresAt: 500_000,
      status: "active",
    };
    expect(hostReconnectDeadline(metadata)).toBe(121_000);
    expect(nextRoomAlarm(metadata)).toBe(121_000);
    expect(hostAvailabilityExpired(metadata, 120_999)).toBe(false);
    expect(hostAvailabilityExpired(metadata, 121_000)).toBe(true);
    expect(hostAvailabilityExpired({ ...metadata, hostConnectedAt: 2_000 }, 121_000)).toBe(false);
    expect(nextRoomAlarm({ ...metadata, hostConnectedAt: 2_000 })).toBe(metadata.expiresAt);
  });
});
