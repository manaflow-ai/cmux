import { describe, expect, test } from "bun:test";
import {
  CODEROUTER_EDGE_ORIGIN_ENV,
  DEFAULT_CODEROUTER_EDGE_ORIGIN,
  VM_ROUTE_TOKEN_LABEL,
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
// There is no plan or entitlement gate: every team gets a token.

const INPUT = { teamId: "team-1", stackUserId: "user-1", cloudVmId: "11111111-2222-4333-8444-555555555555" };

function deps(overrides: Partial<VmModelPlaneDependencies> = {}): VmModelPlaneDependencies {
  return {
    issueToken: async () => ({ token: "crt_test-token", expiresAt: new Date(0) }),
    revokeTokensForVm: async () => undefined,
    edgeOriginEnv: () => undefined,
    vercelEnv: () => undefined,
    vercelBranchUrl: () => undefined,
    vercelBypassSecret: () => undefined,
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

  test("a token issue infrastructure error is a typed unavailable failure", async () => {
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

describe("preview deployments serve themselves as the edge origin", () => {
  test("a Vercel preview uses its branch URL and injects the bypass header", async () => {
    const provision = await provisionVmModelPlane(
      { teamId: "team-1", stackUserId: "user-1", cloudVmId: "11111111-2222-4333-8444-555555555555" },
      deps({
        vercelEnv: () => "preview",
        vercelBranchUrl: () => "cmux-git-feat-manaflow.vercel.app",
        vercelBypassSecret: () => "bypass-secret",
      }),
    );
    expect(provision.envs.OPENAI_BASE_URL).toBe("https://cmux-git-feat-manaflow.vercel.app/v1");
    expect(provision.edgeRules[0]?.domain).toBe("cmux-git-feat-manaflow.vercel.app");
    expect(provision.edgeRules[0]?.headers["x-vercel-protection-bypass"]).toBe("bypass-secret");
  });

  test("an explicit origin wins over the preview branch URL, and production adds no bypass header", async () => {
    const provision = await provisionVmModelPlane(
      { teamId: "team-1", stackUserId: "user-1", cloudVmId: "11111111-2222-4333-8444-555555555555" },
      deps({
        edgeOriginEnv: () => "https://coderouter.dev",
        vercelEnv: () => "production",
        vercelBranchUrl: () => "cmux-git-main-manaflow.vercel.app",
        vercelBypassSecret: () => "bypass-secret",
      }),
    );
    expect(provision.envs.OPENAI_BASE_URL).toBe("https://coderouter.dev/v1");
    expect(provision.edgeRules[0]?.headers["x-vercel-protection-bypass"]).toBeUndefined();
  });
});
