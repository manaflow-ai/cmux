// Cloud VM model-plane env v1: when a Cloud VM is created, mint a coderouter
// route token for the creating user's billing team and hand the machine the
// same env the `cr` CLI would configure locally:
//
//   OPENAI_BASE_URL = <web origin>/v1     (the Responses-compatible data plane)
//   OPENAI_API_KEY  = crt_...             (30-day route token, sha256-stored)
//   CMUX_CODEROUTER_URL = <web origin>    (origin for future config fetches,
//                                          e.g. /api/coderouter/opencode/config)
//
// The baked image's /etc/cmux/agent-config.sh materializes harness configs
// from these vars at first shell and persists them on the machine's durable
// home volume, because provider create-time envs do not survive a resurrect.
// Minting is best-effort by design: a coderouter outage or an entitlement
// block must never fail a VM create, it only ships an unwired machine.
import { coderouterEntitlement } from "./entitlement";
import { issueRouteToken } from "./repository";
import { captureCoderouterError } from "../errors";

export const VM_ROUTE_TOKEN_LABEL = "vm";

export type VmModelPlaneInput = {
  readonly teamId: string;
  readonly stackUserId: string;
  /** Any URL on the serving origin (typically request.url); only the origin is kept. */
  readonly requestUrl: string;
};

export type VmModelPlaneDependencies = {
  readonly issueToken: typeof issueRouteToken;
  readonly entitlement: typeof coderouterEntitlement;
  readonly hostedProRequired: () => boolean;
  readonly enabled: () => boolean;
};

const defaultDependencies: VmModelPlaneDependencies = {
  issueToken: issueRouteToken,
  entitlement: coderouterEntitlement,
  hostedProRequired: () => process.env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
  enabled: () => vmModelPlaneEnabled(process.env.CMUX_VM_CODEROUTER_ENV_ENABLED),
};

/** Kill switch: set CMUX_VM_CODEROUTER_ENV_ENABLED=0 to create unwired VMs. */
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
 * Mint the model-plane env for one new machine, or null when the feature is
 * disabled or the team's hosted entitlement blocks token issuance. Throws on
 * infrastructure errors; use {@link mintVmModelPlaneEnvBestEffort} from
 * request paths that must not fail.
 */
export async function mintVmModelPlaneEnv(
  input: VmModelPlaneInput,
  dependencies: VmModelPlaneDependencies = defaultDependencies,
): Promise<Record<string, string> | null> {
  if (!dependencies.enabled()) return null;
  if (dependencies.hostedProRequired()) {
    const entitlement = await dependencies.entitlement(input.stackUserId, input.teamId);
    if (!entitlement.allowed) return null;
  }
  const origin = new URL(input.requestUrl).origin;
  const { token } = await dependencies.issueToken(
    input.teamId,
    input.stackUserId,
    VM_ROUTE_TOKEN_LABEL,
  );
  return {
    OPENAI_BASE_URL: `${origin}/v1`,
    OPENAI_API_KEY: token,
    CMUX_CODEROUTER_URL: origin,
  };
}

export async function mintVmModelPlaneEnvBestEffort(
  input: VmModelPlaneInput,
  dependencies: VmModelPlaneDependencies = defaultDependencies,
): Promise<Record<string, string> | null> {
  try {
    return await mintVmModelPlaneEnv(input, dependencies);
  } catch (error) {
    captureCoderouterError(error, {
      operation: "mint_vm_model_plane_env",
      route: "/api/vm",
    });
    return null;
  }
}
