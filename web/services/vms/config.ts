import type { ProviderId } from "./drivers";
import { VmCreateDisabledError } from "./errors";

export type VmRuntimeEnv = Record<string, string | undefined>;

export function assertVmCreateEnabled(
  provider: ProviderId,
  env: VmRuntimeEnv = process.env,
): void {
  const reason = vmCreateDisabledReason(provider, env);
  if (reason) {
    throw new VmCreateDisabledError({ provider, reason });
  }
}

/**
 * Why creating a machine on `provider` is disabled, or null when creation is
 * allowed. Workflow code (Effect) uses this instead of the throwing assert so
 * a flipped kill switch is a typed failure, not a thrown defect.
 */
export function vmCreateDisabledReason(
  provider: ProviderId,
  env: VmRuntimeEnv = process.env,
): string | null {
  if (isFalseFlag(env.CMUX_VM_CREATE_ENABLED)) {
    return "Cloud VM creation is disabled";
  }
  if (isFalseFlag(env[providerEnabledEnvKey(provider)])) {
    return `${provider} VM creation is disabled`;
  }
  if (!vmPrivateNetworkEnabled(env)) {
    return "Cloud VM creation requires private networking";
  }
  return null;
}

export function providerEnabledEnvKey(provider: ProviderId): string {
  switch (provider) {
    case "freestyle":
      return "CMUX_VM_FREESTYLE_ENABLED";
    default:
      return assertNever(provider);
  }
}

/**
 * Whether private-network operations are enabled.
 *
 * This is a fail-closed kill switch. Turning it off disables new Cloud VM
 * creation and tunnel enrollment. It never changes a machine to public ingress
 * and it never selects a public route for an existing machine.
 */
export function vmPrivateNetworkEnabled(env: VmRuntimeEnv = process.env): boolean {
  return !isFalseFlag(env.CMUX_VM_PRIVATE_NETWORK_ENABLED);
}

/**
 * The deployment's network namespace, or null for production.
 *
 * Production, staging, and every dev-backend stack share one provider
 * account, and slugs are derived from the Stack user id, so without a
 * namespace every deployment resolved the same user to the same network and
 * tunnel slugs: dev stacks enrolled tunnels into users' production networks.
 * A namespace prefixes every slug this deployment derives. Unset or empty is
 * production and keeps the historical slugs, so existing networks are found
 * unchanged. A malformed value throws instead of falling back to production.
 *
 * At most 16 characters of lowercase letters, digits, and single hyphens,
 * which keeps the longest derived slug inside the provider's 63.
 */
export function vmNetworkNamespace(env: VmRuntimeEnv = process.env): string | null {
  const value = env.CMUX_VM_NETWORK_NAMESPACE?.trim() ?? "";
  if (!value) return null;
  if (value.length > 16 || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value)) {
    throw new Error(
      `CMUX_VM_NETWORK_NAMESPACE must be 1-16 lowercase letters, digits, and single hyphens; got ${JSON.stringify(value)}`,
    );
  }
  return value;
}

/**
 * The slug prefix for one kind of provider resource (`net`, `team-net`, `wg`)
 * in a namespace; `cmux-<kind>` for production.
 */
export function vmNetworkSlugPrefix(kind: "net" | "team-net" | "wg", namespace: string | null): string {
  return namespace ? `cmux-${namespace}-${kind}` : `cmux-${kind}`;
}

export function isDeployedRuntime(env: VmRuntimeEnv = process.env): boolean {
  return env.VERCEL === "1" ||
    env.VERCEL_ENV === "production" ||
    env.VERCEL_ENV === "preview" ||
    env.VERCEL_ENV === "staging";
}

export function allowUnmanifestedImages(env: VmRuntimeEnv = process.env): boolean {
  return isTrueFlag(env.CMUX_VM_ALLOW_UNMANIFESTED_IMAGES) || !isDeployedRuntime(env);
}


function isFalseFlag(value: string | undefined): boolean {
  if (value === undefined) return false;
  switch (value.trim().toLowerCase()) {
    case "0":
    case "false":
    case "no":
    case "off":
    case "disabled":
      return true;
    default:
      return false;
  }
}

function isTrueFlag(value: string | undefined): boolean {
  if (value === undefined) return false;
  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
    case "enabled":
      return true;
    default:
      return false;
  }
}

function assertNever(value: never): never {
  throw new Error(`unsupported VM provider: ${String(value)}`);
}
