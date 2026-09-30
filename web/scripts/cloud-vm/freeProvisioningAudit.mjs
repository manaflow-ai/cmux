// Mirror of services/vms/entitlements.ts `isVmFreeProvisioningAllowed`. The
// audit script must stay a dependency-free .mjs for CI, so it cannot import
// the runtime module; tests/cloud-vm-env-audit.test.ts pins the two together.

export const FREE_PROVISIONING_ALLOW_KEY = "CMUX_VM_ALLOW_FREE_PROVISIONING";
export const FREE_PROVISIONING_LEGACY_KEY = "CMUX_VM_REQUIRE_PRO";
export const freeProvisioningOverrideEnvKeys = [
  FREE_PROVISIONING_ALLOW_KEY,
  FREE_PROVISIONING_LEGACY_KEY,
];

const SENSITIVE_PLACEHOLDER = "[SENSITIVE]";
const TRUTHY = new Set(["1", "true", "yes", "on", "enabled"]);
const FALSY = new Set(["0", "false", "no", "off", "disabled"]);

function normalized(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

/** Same decision the runtime makes: does this env open free-plan provisioning? */
export function isFreeProvisioningAllowed(env) {
  const allow = env[FREE_PROVISIONING_ALLOW_KEY];
  if (allow !== undefined) return TRUTHY.has(normalized(allow));
  const legacy = env[FREE_PROVISIONING_LEGACY_KEY];
  return legacy !== undefined && FALSY.has(normalized(legacy));
}

/**
 * Key presence is not enough here: `CMUX_VM_ALLOW_FREE_PROVISIONING=0` is a
 * harmless explicit default, while `=1` (or a lone legacy
 * `CMUX_VM_REQUIRE_PRO=0`) silently reopens free provisioning in a shared
 * environment. Any problem fails the audit.
 */
export function auditFreeProvisioningOverride(env) {
  const present = freeProvisioningOverrideEnvKeys.filter((key) => env[key] !== undefined);
  const problems = [];
  for (const key of present) {
    if (env[key] === SENSITIVE_PLACEHOLDER) {
      problems.push(
        `${key} is stored as a Sensitive env var, so its value cannot be audited and the ` +
          "paid-plan gate state is unknown; store it as a plain env var or unset it",
      );
    }
  }
  const allowed = problems.length === 0 && isFreeProvisioningAllowed(env);
  if (allowed) {
    const cause = env[FREE_PROVISIONING_ALLOW_KEY] !== undefined
      ? `${FREE_PROVISIONING_ALLOW_KEY}=${env[FREE_PROVISIONING_ALLOW_KEY]}`
      : `legacy ${FREE_PROVISIONING_LEGACY_KEY}=${env[FREE_PROVISIONING_LEGACY_KEY]} with ` +
        `${FREE_PROVISIONING_ALLOW_KEY} unset`;
    problems.push(
      `free Cloud VM provisioning is enabled (${cause}); shared environments must keep the ` +
        `paid-plan gate on. Unset ${FREE_PROVISIONING_ALLOW_KEY} and ${FREE_PROVISIONING_LEGACY_KEY}, ` +
        `or set ${FREE_PROVISIONING_ALLOW_KEY}=0`,
    );
  }
  return { present, allowed, problems };
}
