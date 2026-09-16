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
  VM_REFLECTION_ALIAS_HEADER,
  VM_REFLECTION_ALIAS_VALUE,
  vmGuestModelPlaneEnv,
} from "../services/coderouter/vmGuestEnv";
import {
  ROUTE_TOKEN_HEADER,
  VM_ID_HEADER,
  VM_PLACEHOLDER_API_KEY,
} from "../services/coderouter/routeTokenAuth";
import { freestyleEdgeRules } from "../services/vms/drivers/freestyle";
import { validateTlsSpec } from "freestyle";

// The Cloud VM model plane: a new machine gets base URLs and placeholder keys
// in its env, and edge rules that inject a route token bound to the VM row id:
// one for the coderouter alias, one for the reflection alias (same token, plus
// the marker the proxy routes on). The token never appears in the env; the edge injects both a bearer
// and the explicit route headers on the wire. Provisioning failures are
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
  test("mints a VM-bound token and returns the coderouter and reflection alias rules", async () => {
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
    // The guest dials the alias; the edge forwards to this deployment's host.
    const headers = {
      authorization: "Bearer crt_test-token",
      [ROUTE_TOKEN_HEADER]: "crt_test-token",
      [VM_ID_HEADER]: INPUT.cloudVmId,
    };
    expect(provision.edgeRules).toEqual([
      { domain: "coderouter.cmux.internal", destinationHost: "coderouter.dev", headers },
      // Reflection: the same identity, plus the marker the proxy routes on.
      {
        domain: "reflection.cmux.internal",
        destinationHost: "coderouter.dev",
        headers: { ...headers, [VM_REFLECTION_ALIAS_HEADER]: VM_REFLECTION_ALIAS_VALUE },
      },
    ]);
  });

  test("nothing the guest sees carries a route token", async () => {
    const provision = await provisionVmModelPlane(INPUT, deps());
    expect(provision.edgeRules[0]?.domain).not.toMatch(/crt_/);
    expect(JSON.stringify(vmGuestModelPlaneEnv())).not.toContain("crt_");
  });

  test("the provisioned rule is a valid Freestyle egress TLS spec", async () => {
    const provision = await provisionVmModelPlane(INPUT, deps());
    const rules = freestyleEdgeRules(provision.edgeRules);
    expect(rules).toHaveLength(2);
    expect(() => validateTlsSpec({ rules })).not.toThrow();
    for (const rule of rules ?? []) {
      expect(rule).toMatchObject({
        source: {},
        destination: { host: "coderouter.dev", port: 443 },
        transform: [{ headers: { authorization: "Bearer crt_test-token" } }],
      });
    }
    expect(rules?.[1]?.transform[0]?.headers).toMatchObject({ [VM_REFLECTION_ALIAS_HEADER]: VM_REFLECTION_ALIAS_VALUE });
  });

  test("the origin override points the edge rule at a preview deployment", async () => {
    const provision = await provisionVmModelPlane(
      INPUT,
      deps({ edgeOriginEnv: () => "https://cmux-git-feat-manaflow.vercel.app/" }),
    );
    expect(provision.edgeRules.map((rule) => rule.domain)).toEqual(["coderouter.cmux.internal", "reflection.cmux.internal"]);
    expect(provision.edgeRules.every((rule) => rule.destinationHost === "cmux-git-feat-manaflow.vercel.app")).toBe(true);
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
    expect(provision.edgeRules[0]?.destinationHost).toBe("cmux-git-feat-manaflow.vercel.app");
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
    expect(provision.edgeRules[0]?.destinationHost).toBe("coderouter.dev");
    expect(provision.edgeRules[0]?.headers["x-vercel-protection-bypass"]).toBeUndefined();
  });
});
