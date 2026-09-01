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
  return null;
}

export function providerEnabledEnvKey(provider: ProviderId): string {
  switch (provider) {
    case "e2b":
      return "CMUX_VM_E2B_ENABLED";
    case "freestyle":
      return "CMUX_VM_FREESTYLE_ENABLED";
    case "daytona":
      return "CMUX_VM_DAYTONA_ENABLED";
    case "blaxel":
      return "CMUX_VM_BLAXEL_ENABLED";
    default:
      return assertNever(provider);
  }
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
