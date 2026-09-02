// Cloud VM model plane: how a machine reaches coderouter without holding a
// credential. At create, the control plane mints one route token bound to
// the cmux Cloud VM row id and hands the provider an edge rule for the
// coderouter host. The provider's TLS edge injects `x-coderouter-route-token`
// and `x-cmux-vm-id` into every request the guest makes to that host; the
// guest env carries only OPENAI_BASE_URL / ANTHROPIC_BASE_URL and a public
// placeholder key. coderouter rejects the token when the injected VM id
// differs from the binding, so a rule cannot be reused for another machine.
//
// Provisioning is mandatory: a coderouter outage fails the create and the
// workflow rolls the machine back. There is no plan or entitlement gate;
// every team member's machine gets a token. The only exception is the
// local-dev kill switch CMUX_VM_CODEROUTER_ENV_ENABLED=0, which creates an
// unwired machine (no env, no rule, still no secret). Never set it in
// production. Tokens never rotate; destroy revokes them.
import { issueRouteToken, revokeRouteTokensForVm } from "./repository";
import { ROUTE_TOKEN_HEADER, VM_ID_HEADER, VM_PLACEHOLDER_API_KEY } from "./routeTokenAuth";
import type { VmEdgeRule } from "../vms/drivers/types";

export const VM_ROUTE_TOKEN_LABEL = "vm";
export const DEFAULT_CODEROUTER_EDGE_ORIGIN = "https://coderouter.dev";
export const CODEROUTER_EDGE_ORIGIN_ENV = "CMUX_CODEROUTER_EDGE_ORIGIN";

export type VmModelPlaneInput = {
  readonly teamId: string;
  readonly stackUserId: string;
  /** The `cloud_vms.id` the token is bound to; the edge sends it as `x-cmux-vm-id`. */
  readonly cloudVmId: string;
};

export type VmModelPlaneProvision = {
  /** Guest env: base URLs, placeholder keys, the VM id. Never a token. */
  readonly envs: Record<string, string>;
  /** Edge header injection for the coderouter host. Holds the token. */
  readonly edgeRules: readonly VmEdgeRule[];
};

/** Token issuance or its prerequisites failed (database, config). Retryable. */
export class VmModelPlaneUnavailableError extends Error {
  constructor(message: string, public readonly cause?: unknown) {
    super(message);
    this.name = "VmModelPlaneUnavailableError";
  }
}

export type VmModelPlaneDependencies = {
  readonly issueToken: typeof issueRouteToken;
  readonly revokeTokensForVm: typeof revokeRouteTokensForVm;
  /** The raw CMUX_CODEROUTER_EDGE_ORIGIN value; validated by {@link coderouterEdgeOrigin}. */
  readonly edgeOriginEnv: () => string | undefined;
  /** Vercel deployment facts: a preview serves itself as the edge origin. */
  readonly vercelEnv: () => string | undefined;
  readonly vercelBranchUrl: () => string | undefined;
  /** Vercel's automation bypass secret; injected so the edge can reach an SSO-protected preview. */
  readonly vercelBypassSecret: () => string | undefined;
};

export const VERCEL_BYPASS_HEADER = "x-vercel-protection-bypass";

const defaultDependencies: VmModelPlaneDependencies = {
  issueToken: issueRouteToken,
  revokeTokensForVm: revokeRouteTokensForVm,
  edgeOriginEnv: () => process.env[CODEROUTER_EDGE_ORIGIN_ENV],
  vercelEnv: () => process.env.VERCEL_ENV,
  vercelBranchUrl: () => process.env.VERCEL_BRANCH_URL,
  vercelBypassSecret: () => process.env.VERCEL_AUTOMATION_BYPASS_SECRET,
};

/**
 * The origin guests dial. An explicit CMUX_CODEROUTER_EDGE_ORIGIN wins; a
 * Vercel preview serves itself (its branch URL), so a PR can be tested end to
 * end without touching production; otherwise coderouter.dev.
 */
export function resolveEdgeOrigin(dependencies: Pick<VmModelPlaneDependencies, "edgeOriginEnv" | "vercelEnv" | "vercelBranchUrl">): string {
  const explicit = dependencies.edgeOriginEnv()?.trim();
  if (explicit) return coderouterEdgeOrigin(explicit);
  const branchUrl = dependencies.vercelBranchUrl()?.trim();
  if (dependencies.vercelEnv() === "preview" && branchUrl) {
    return coderouterEdgeOrigin(`https://${branchUrl.replace(/^https?:\/\//, "")}`);
  }
  return DEFAULT_CODEROUTER_EDGE_ORIGIN;
}

/** Extra headers the edge must add for the origin to be reachable at all (preview SSO bypass). */
export function edgeOriginHeaders(dependencies: Pick<VmModelPlaneDependencies, "vercelEnv" | "vercelBypassSecret">): Record<string, string> {
  const secret = dependencies.vercelBypassSecret()?.trim();
  if (dependencies.vercelEnv() === "preview" && secret) return { [VERCEL_BYPASS_HEADER]: secret };
  return {};
}

/**
 * Local-dev kill switch: CMUX_VM_CODEROUTER_ENV_ENABLED=0 creates unwired
 * machines (no env, no edge rule). It exists so a checkout without a
 * coderouter database can still create machines. Never set it in production.
 */
export function vmModelPlaneEnabled(flag: string | undefined): boolean {
  if (flag === undefined) return true;
  switch (flag.trim().toLowerCase()) {
    case "0":
    case "false":
    case "no":
    case "off":
    case "disabled":
      return false;
    default:
      return true;
  }
}

/**
 * The origin guests dial for coderouter. Defaults to the public host; a
 * Vercel preview can be tested by pointing CMUX_CODEROUTER_EDGE_ORIGIN at it.
 * Must be a bare https origin: the edge rule matches a host name, so a path,
 * query, explicit port, or plain http is a configuration error.
 */
export function coderouterEdgeOrigin(raw: string | undefined): string {
  const value = raw?.trim();
  if (!value) return DEFAULT_CODEROUTER_EDGE_ORIGIN;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${CODEROUTER_EDGE_ORIGIN_ENV} must be an https:// origin, got ${JSON.stringify(value)}`);
  }
  if (url.protocol !== "https:" || url.port || url.username || url.password) {
    throw new Error(`${CODEROUTER_EDGE_ORIGIN_ENV} must be a bare https:// origin without port or credentials`);
  }
  if ((url.pathname !== "/" && url.pathname !== "") || url.search || url.hash) {
    throw new Error(`${CODEROUTER_EDGE_ORIGIN_ENV} must not carry a path, query, or fragment`);
  }
  return url.origin;
}

/** The guest env for one origin and VM id. No token anywhere. */
export function vmModelPlaneEnvs(origin: string, cloudVmId: string): Record<string, string> {
  return {
    OPENAI_BASE_URL: `${origin}/v1`,
    OPENAI_API_KEY: VM_PLACEHOLDER_API_KEY,
    CMUX_CODEROUTER_URL: origin,
    ANTHROPIC_BASE_URL: origin,
    ANTHROPIC_API_KEY: VM_PLACEHOLDER_API_KEY,
    CMUX_VM_ID: cloudVmId,
  };
}

/**
 * Mint the machine's route token and build its edge rule and env. Throws
 * {@link VmModelPlaneUnavailableError} on any failure; callers fail the
 * create on it.
 */
export async function provisionVmModelPlane(
  input: VmModelPlaneInput,
  dependencies: VmModelPlaneDependencies = defaultDependencies,
): Promise<VmModelPlaneProvision> {
  let origin: string;
  try {
    origin = resolveEdgeOrigin(dependencies);
  } catch (err) {
    throw new VmModelPlaneUnavailableError(errorMessage(err), err);
  }
  let token: string;
  try {
    ({ token } = await dependencies.issueToken(
      input.teamId,
      input.stackUserId,
      VM_ROUTE_TOKEN_LABEL,
      { vmId: input.cloudVmId },
    ));
  } catch (err) {
    throw new VmModelPlaneUnavailableError(`coderouter route token issue failed: ${errorMessage(err)}`, err);
  }
  return {
    envs: vmModelPlaneEnvs(origin, input.cloudVmId),
    edgeRules: [
      {
        domain: new URL(origin).hostname,
        headers: {
          ...edgeOriginHeaders(dependencies),
          [ROUTE_TOKEN_HEADER]: token,
          [VM_ID_HEADER]: input.cloudVmId,
        },
      },
    ],
  };
}

/** Revoke every route token bound to the machine. Idempotent. */
export async function revokeVmModelPlane(
  cloudVmId: string,
  dependencies: VmModelPlaneDependencies = defaultDependencies,
): Promise<void> {
  await dependencies.revokeTokensForVm(cloudVmId);
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
