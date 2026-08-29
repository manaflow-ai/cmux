import { describe, expect, test } from "bun:test";
import {
  VM_ROUTE_TOKEN_LABEL,
  mintVmModelPlaneEnv,
  mintVmModelPlaneEnvBestEffort,
  vmModelPlaneEnabled,
  type VmModelPlaneDependencies,
} from "../services/coderouter/vmModelPlane";

// The Cloud VM model-plane mint: a new machine gets OPENAI_BASE_URL pointed
// at this deployment's /v1 Responses plane plus a per-machine route token,
// and the mint can never fail a VM create.

function deps(overrides: Partial<VmModelPlaneDependencies> = {}): VmModelPlaneDependencies {
  return {
    issueToken: async () => ({ token: "crt_test-token", expiresAt: new Date(0) }),
    entitlement: async () => ({ allowed: true, basis: "test", accountCount: 0 }) as never,
    hostedProRequired: () => false,
    enabled: () => true,
    ...overrides,
  };
}

describe("mintVmModelPlaneEnv", () => {
  test("mints the /v1 plane env from the serving origin", async () => {
    let labeled: string | undefined;
    const env = await mintVmModelPlaneEnv(
      { teamId: "team-1", stackUserId: "user-1", requestUrl: "https://cmux.example/api/vm?x=1" },
      deps({
        issueToken: async (_team, _user, label) => {
          labeled = label;
          return { token: "crt_test-token", expiresAt: new Date(0) };
        },
      }),
    );
    expect(env).toEqual({
      OPENAI_BASE_URL: "https://cmux.example/v1",
      OPENAI_API_KEY: "crt_test-token",
      CMUX_CODEROUTER_URL: "https://cmux.example",
    });
    expect(labeled).toBe(VM_ROUTE_TOKEN_LABEL);
  });

  test("returns null when the kill switch disables it", async () => {
    const env = await mintVmModelPlaneEnv(
      { teamId: "team-1", stackUserId: "user-1", requestUrl: "https://cmux.example/api/vm" },
      deps({ enabled: () => false }),
    );
    expect(env).toBeNull();
  });

  test("returns null when the hosted entitlement blocks token issuance", async () => {
    const env = await mintVmModelPlaneEnv(
      { teamId: "team-1", stackUserId: "user-1", requestUrl: "https://cmux.example/api/vm" },
      deps({
        hostedProRequired: () => true,
        entitlement: async () => ({ allowed: false, basis: "test", accountCount: 9 }) as never,
      }),
    );
    expect(env).toBeNull();
  });

  test("skips the entitlement read when hosted gating is off", async () => {
    let entitlementCalls = 0;
    await mintVmModelPlaneEnv(
      { teamId: "team-1", stackUserId: "user-1", requestUrl: "https://cmux.example/api/vm" },
      deps({
        entitlement: (async () => {
          entitlementCalls += 1;
          return { allowed: true, basis: "test", accountCount: 0 };
        }) as never,
      }),
    );
    expect(entitlementCalls).toBe(0);
  });

  test("best-effort mint swallows infrastructure errors into null", async () => {
    const env = await mintVmModelPlaneEnvBestEffort(
      { teamId: "team-1", stackUserId: "user-1", requestUrl: "https://cmux.example/api/vm" },
      deps({
        issueToken: async () => {
          throw new Error("db down");
        },
      }),
    );
    expect(env).toBeNull();
  });
});

describe("vmModelPlaneEnabled", () => {
  test("defaults on, disables on false-flags only", () => {
    expect(vmModelPlaneEnabled(undefined)).toBe(true);
    expect(vmModelPlaneEnabled("1")).toBe(true);
    expect(vmModelPlaneEnabled("true")).toBe(true);
    for (const flag of ["0", "false", "no", "off", "disabled", " OFF "]) {
      expect(vmModelPlaneEnabled(flag)).toBe(false);
    }
  });
});
