import { beforeEach, describe, expect, mock, test } from "bun:test";

// Shipped Macs withdraw an app instance with PATCH /api/devices and repeat the
// withdrawal on every status tick until it answers 2xx. Every build on a Mac
// shares one device id, so a second account on that Mac withdraws a device row
// it does not own. The old 403 made those Macs retry forever, ~250k requests
// and Stack verifications a day in production (2026-10-12, 99% of PATCHes
// answered 403). A withdrawal is idempotent: when the caller owns no such
// device in the team, nothing of theirs is published there, which is the
// state the withdrawal asks for.

const getUser = mock(async () => ({
  id: "registry-user-2",
  displayName: null,
  primaryEmail: "registry-user-2@example.com",
  selectedTeam: { id: "team-a" },
  listTeams: async () => [{ id: "team-a" }],
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const Effect = await import("effect/Effect");
const withdrawals: unknown[] = [];
let withdrawalResult: { kind: "withdrawn" | "not_found" | "not_owned" } = { kind: "not_owned" };
mock.module("../services/iroh/deviceRegistryWithdrawal", () => ({
  withdrawDeviceInstance: (input: unknown) => {
    withdrawals.push(input);
    return Effect.succeed(withdrawalResult);
  },
}));

const { PATCH } = await import("../app/api/devices/route");
const { clearNativeAuthCacheForTests } = await import("../services/vms/auth");

const DEVICE = "6f1f6f0e-8f5a-4d55-9a37-7f6c0b1a2c3d";

function withdrawRequest(): Request {
  return new Request("https://cmux.test/api/devices", {
    method: "PATCH",
    headers: {
      authorization: "Bearer access-2",
      "x-stack-refresh-token": "refresh-2",
      "content-type": "application/json",
    },
    body: JSON.stringify({ deviceId: DEVICE, tag: "default" }),
  });
}

beforeEach(() => {
  clearNativeAuthCacheForTests();
  withdrawals.length = 0;
  withdrawalResult = { kind: "not_owned" };
});

describe("PATCH /api/devices withdrawal", () => {
  test("a device the caller does not own answers success with nothing withdrawn", async () => {
    const response = await PATCH(withdrawRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, withdrawn: false });
    expect(withdrawals).toEqual([{ deviceUuid: DEVICE, tag: "default", teamId: "team-a", userId: "registry-user-2" }]);
  });

  test("an owned instance is still reported as withdrawn", async () => {
    withdrawalResult = { kind: "withdrawn" };
    const response = await PATCH(withdrawRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, withdrawn: true });
  });
});
