import { describe, expect, test } from "bun:test";
import {
  CODEROUTER_EDGE_ORIGIN_ENV,
  DEFAULT_CODEROUTER_EDGE_ORIGIN,
  VM_ROUTE_TOKEN_LABEL,
  VmModelPlaneEntitlementError,
  VmModelPlaneUnavailableError,
  coderouterEdgeOrigin,
  provisionVmModelPlane,
  revokeVmModelPlane,
  vmModelPlaneEnabled,
  type VmModelPlaneDependencies,
} from "../services/coderouter/vmModelPlane";
import {
  ROUTE_TOKEN_HEADER,
  VM_ID_HEADER,
  VM_PLACEHOLDER_API_KEY,
} from "../services/coderouter/routeTokenAuth";

// The Cloud VM model plane: a new machine gets base URLs and placeholder keys
// in its env, and ONE edge rule that injects a route token bound to the VM
// row id. The token never appears in the env. Provisioning failures are
// typed so the workflow fails the create instead of shipping an unwired box.

const INPUT = { teamId: "team-1", stackUserId: "user-1", cloudVmId: "11111111-2222-4333-8444-555555555555" };

function deps(overrides: Partial<VmModelPlaneDependencies> = {}): VmModelPlaneDependencies {
  return {
    issueToken: async () => ({ token: "crt_test-token", expiresAt: new Date(0) }),
    revokeTokensForVm: async () => undefined,
    entitlement: async () => ({ allowed: true, basis: "free_tier", accountCount: 0 }),
    hostedProRequired: () => false,
    edgeOriginEnv: () => undefined,
    ...overrides,
  };
}

describe("provisionVmModelPlane", () => {
  test("mints a VM-bound token and returns placeholder env plus one edge rule", async () => {
    const issued: unknown[] = [];
    const provision = await provisionVmModelPlane(
      INPUT,
      deps({
        issueToken: async (...args) => {
          issued.push(args);
          return { token: "crt_test-token", expiresAt: new Date(0) };
        },
      }),
    );
    expect(issued).toEqual([["team-1", "user-1", VM_ROUTE_TOKEN_LABEL, { vmId: INPUT.cloudVmId }]]);
    expect(provision.envs).toEqual({
      OPENAI_BASE_URL: "https://coderouter.dev/v1",
      OPENAI_API_KEY: VM_PLACEHOLDER_API_KEY,
      CMUX_CODEROUTER_URL: "https://coderouter.dev",
      ANTHROPIC_BASE_URL: "https://coderouter.dev",
      ANTHROPIC_API_KEY: VM_PLACEHOLDER_API_KEY,
      CMUX_VM_ID: INPUT.cloudVmId,
    });
    expect(provision.edgeRules).toEqual([
      {
        domain: "coderouter.dev",
        headers: {
          [ROUTE_TOKEN_HEADER]: "crt_test-token",
          [VM_ID_HEADER]: INPUT.cloudVmId,
        },
      },
    ]);
  });

  test("no env value is ever a route token", async () => {
    const provision = await provisionVmModelPlane(INPUT, deps());
    for (const value of Object.values(provision.envs)) {
      expect(value).not.toMatch(/crt_/);
    }
    expect(JSON.stringify(provision.envs)).not.toContain("crt_");
  });

  test("the origin override points env and the edge rule at a preview deployment", async () => {
    const provision = await provisionVmModelPlane(
      INPUT,
      deps({ edgeOriginEnv: () => "https://cmux-git-feat-manaflow.vercel.app/" }),
    );
    expect(provision.envs.OPENAI_BASE_URL).toBe("https://cmux-git-feat-manaflow.vercel.app/v1");
    expect(provision.envs.ANTHROPIC_BASE_URL).toBe("https://cmux-git-feat-manaflow.vercel.app");
    expect(provision.envs.CMUX_CODEROUTER_URL).toBe("https://cmux-git-feat-manaflow.vercel.app");
    expect(provision.edgeRules[0]?.domain).toBe("cmux-git-feat-manaflow.vercel.app");
  });

  test("an invalid origin override is a typed unavailable failure, not a create with a bad rule", async () => {
    let issued = 0;
    await expect(
      provisionVmModelPlane(
        INPUT,
        deps({
          edgeOriginEnv: () => "http://coderouter.dev",
          issueToken: async () => {
            issued += 1;
            return { token: "crt_x", expiresAt: new Date(0) };
          },
        }),
      ),
    ).rejects.toBeInstanceOf(VmModelPlaneUnavailableError);
    expect(issued).toBe(0);
  });

  test("a blocked hosted entitlement is a typed entitlement failure and issues nothing", async () => {
    let issued = 0;
    const failure = await provisionVmModelPlane(
      INPUT,
      deps({
        hostedProRequired: () => true,
        entitlement: async () => ({ allowed: false, basis: "pro_required", accountCount: 9 }),
        issueToken: async () => {
          issued += 1;
          return { token: "crt_x", expiresAt: new Date(0) };
        },
      }),
    ).catch((err: unknown) => err);
    expect(failure).toBeInstanceOf(VmModelPlaneEntitlementError);
    expect((failure as VmModelPlaneEntitlementError).teamId).toBe("team-1");
    expect(issued).toBe(0);
  });

  test("skips the entitlement read when hosted gating is off", async () => {
    let entitlementCalls = 0;
    await provisionVmModelPlane(
      INPUT,
      deps({
        entitlement: async () => {
          entitlementCalls += 1;
          return { allowed: true, basis: "free_tier", accountCount: 0 };
        },
      }),
    );
    expect(entitlementCalls).toBe(0);
  });

  test("token issue and entitlement infrastructure errors are typed unavailable failures", async () => {
    await expect(
      provisionVmModelPlane(
        INPUT,
        deps({
          issueToken: async () => {
            throw new Error("db down");
          },
        }),
      ),
    ).rejects.toBeInstanceOf(VmModelPlaneUnavailableError);
    await expect(
      provisionVmModelPlane(
        INPUT,
        deps({
          hostedProRequired: () => true,
          entitlement: async () => {
            throw new Error("stripe down");
          },
        }),
      ),
    ).rejects.toBeInstanceOf(VmModelPlaneUnavailableError);
  });
});

describe("revokeVmModelPlane", () => {
  test("revokes every token bound to the VM row", async () => {
    const revoked: string[] = [];
    await revokeVmModelPlane(
      INPUT.cloudVmId,
      deps({
        revokeTokensForVm: async (vmId) => {
          revoked.push(vmId);
        },
      }),
    );
    expect(revoked).toEqual([INPUT.cloudVmId]);
  });
});

describe("coderouterEdgeOrigin", () => {
  test("defaults to the public host and accepts a bare https origin", () => {
    expect(coderouterEdgeOrigin(undefined)).toBe(DEFAULT_CODEROUTER_EDGE_ORIGIN);
    expect(coderouterEdgeOrigin("  ")).toBe(DEFAULT_CODEROUTER_EDGE_ORIGIN);
    expect(coderouterEdgeOrigin("https://cmux-git-x-manaflow.vercel.app")).toBe(
      "https://cmux-git-x-manaflow.vercel.app",
    );
    expect(coderouterEdgeOrigin("https://cmux-git-x-manaflow.vercel.app/")).toBe(
      "https://cmux-git-x-manaflow.vercel.app",
    );
  });

  test("rejects anything an edge rule cannot express", () => {
    for (const bad of [
      "http://coderouter.dev",
      "https://coderouter.dev:8443",
      "https://coderouter.dev/v1",
      "https://coderouter.dev/?x=1",
      "https://user:pw@coderouter.dev",
      "coderouter.dev",
    ]) {
      expect(() => coderouterEdgeOrigin(bad)).toThrow(CODEROUTER_EDGE_ORIGIN_ENV);
    }
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
