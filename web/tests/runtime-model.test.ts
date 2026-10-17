import { describe, expect, test } from "bun:test";
import { toRuntimeView, type RuntimeRow } from "../services/vms/runtimeModel";

const runtime = {
  id: "00000000-0000-4000-8000-000000000001",
  ownerTeamId: "team-runtime",
  runtimeKind: "persistent",
  lifecycleState: "ready",
  journalSessionId: "journal-private",
  machineId: "00000000-0000-4000-8000-000000000002",
  placementGeneration: 3,
  leaseToken: "lease-private",
  leaseGeneration: 4,
  leaseExpiresAt: new Date("2026-10-17T01:00:00.000Z"),
  idempotencyKey: "request-private",
  createdAt: new Date("2026-10-17T00:00:00.000Z"),
  updatedAt: new Date("2026-10-17T00:30:00.000Z"),
  releasedAt: null,
} as RuntimeRow;

describe("Runtime public model", () => {
  test("exposes lifecycle and placement generation without private handles", () => {
    const view = toRuntimeView(runtime);
    expect(view).toEqual({
      id: runtime.id,
      kind: "persistent",
      lifecycleState: "ready",
      placementGeneration: 3,
      createdAt: "2026-10-17T00:00:00.000Z",
      updatedAt: "2026-10-17T00:30:00.000Z",
      releasedAt: null,
    });
    expect(view).not.toHaveProperty("ownerTeamId");
    expect(view).not.toHaveProperty("machineId");
    expect(view).not.toHaveProperty("journalSessionId");
    expect(view).not.toHaveProperty("leaseToken");
    expect(view).not.toHaveProperty("idempotencyKey");
  });
});
