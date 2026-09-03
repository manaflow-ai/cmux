// Coherence check between the deployed Cloud VM env and the image manifest.
//
// The 2026-08-26 outage: code shipped assuming one CMUX_VM_DEFAULT_PROVIDER
// while production still said another, and no image selector was set for it.
// Key-presence auditing could not catch that; provider VALUES have to agree
// with the manifest. Image env vars derive from manifest.json (each entry
// carries its provider and env var), so a new provider cannot be added
// without this audit learning about it.

/**
 * Provider API credential env keys. These cannot be derived from the manifest;
 * keep in sync with services/vms/drivers/*.
 */
const PROVIDER_CREDENTIAL_KEYS = {
  freestyle: ["FREESTYLE_API_KEY"],
};

// Runtime kill switches are fail-open when unset, but an explicit false value
// disables the provider. Keep this mapping beside the credential mapping so a
// new default provider cannot pass the audit while its create path is off.
const PROVIDER_ENABLED_KEYS = {
  freestyle: "CMUX_VM_FREESTYLE_ENABLED",
};

// Mirrors defaultProviderId() in services/vms/drivers/index.ts. Freestyle is
// the only provider, and shipped CLIs hardcode its image ids (cmux.swift
// cloudVMDesktopImage / cloudVMBaseImage), so it must stay provisionable in
// production.
export const CODE_DEFAULT_PROVIDER = "freestyle";

// What `vercel env pull` writes for values it cannot decrypt. The default
// provider and its image id are configuration, not secrets; stored as
// Sensitive they become unauditable, which defeats this check.
const SENSITIVE_PLACEHOLDER = "[SENSITIVE]";

/**
 * Audit one provider: its image env var must name a validated manifest entry
 * and its API credentials must exist.
 *
 * @param {string} provider
 * @param {Record<string, string | undefined>} env deployed runtime env values
 * @param {{ images: Array<{ provider: string, version: string, imageId: string, envVar: string, validationStatus: string }> }} manifest
 * @returns {{ provider: string, envVar: string | null, image: string | null, imageSource?: string, problems: string[] }}
 */
export function auditProviderReadiness(provider, env, manifest) {
  const problems = [];
  const entries = manifest.images.filter((entry) => entry.provider === provider);
  if (entries.length === 0) {
    problems.push(
      `provider ${provider} has no entries in the image manifest; ` +
      "every imageless create will fail closed in deployed runtimes",
    );
    return { provider, envVar: null, image: null, problems };
  }

  // The checked-in manifest is the only source of truth for images: deployed
  // runtimes serve the entry flagged defaultForKind (services/vms/images/
  // resolver.ts). No env var selects an image any more; a lingering selector
  // is stale configuration that would mislead whoever reads the deployment.
  const envVar = entries[0].envVar;
  const kindDefaults = entries.filter((entry) => entry.defaultForKind === true);
  for (const entry of kindDefaults.filter((entry) => entry.validationStatus !== "passed")) {
    problems.push(
      `manifest default ${entry.version} (${entry.kind ?? "base"}) for ${provider} has ` +
      `validationStatus ${entry.validationStatus}, not passed`,
    );
  }
  // Only a validated default counts as the served image: an unvalidated one
  // is already reported above and must not be echoed back as the selection.
  const baseDefault = kindDefaults.find(
    (entry) => (entry.kind ?? "base") === "base" && entry.validationStatus === "passed",
  );
  const image = baseDefault?.imageId ?? null;
  if (!baseDefault) {
    problems.push(
      `the manifest has no validated base default for ${provider} (no entry flagged ` +
      "defaultForKind); deployed runtimes fail closed on imageless creates",
    );
  }
  if (envVar && env[envVar] !== undefined) {
    problems.push(
      `${envVar} is set but ignored: the manifest is the source of truth for images; ` +
      "remove it from the deployment",
    );
  }

  const credentialKeys = PROVIDER_CREDENTIAL_KEYS[provider];
  if (!credentialKeys) {
    // Fail closed: a provider without a credential mapping would otherwise
    // pass this audit and then fail every create at runtime.
    problems.push(
      `provider ${provider} has no credential mapping in this audit; ` +
      "add its API credential env keys to PROVIDER_CREDENTIAL_KEYS",
    );
  }
  for (const key of credentialKeys ?? []) {
    if (!env[key]?.trim()) {
      problems.push(`${key} is not set but provider ${provider} must be provisionable`);
    }
  }

  const enabledKey = PROVIDER_ENABLED_KEYS[provider];
  const enabledValue = enabledKey ? env[enabledKey]?.trim() : undefined;
  if (enabledKey && enabledValue === SENSITIVE_PLACEHOLDER) {
    problems.push(
      `${enabledKey} is stored as a Sensitive env var, so its value cannot be audited; ` +
      "store it as a plain env var (provider switches are configuration, not secrets)",
    );
  } else if (enabledKey && isFalseFlag(enabledValue)) {
    problems.push(`${enabledKey} disables provider ${provider}, so the selected default cannot create VMs`);
  }

  return { provider, envVar, image, imageSource: "manifest", problems };
}

function isFalseFlag(value) {
  if (!value) return false;
  return ["0", "false", "no", "off", "disabled"].includes(value.toLowerCase());
}

/**
 * Full coherence audit. Two legs:
 * - the env-selected default provider (what imageless creates use), and
 * - the code default (freestyle) whenever the env selects something else,
 *   because shipped clients hardcode the code default's image ids: an env
 *   rollback to another default must not leave it unprovisionable. This leg
 *   is what would have caught the 2026-08-26 production env, where a fully
 *   coherent env default coexisted with clients that only send the code default.
 *
 * @param {Record<string, string | undefined>} env
 * @param {{ images: Array<{ provider: string, version: string, imageId: string, envVar: string, validationStatus: string }> }} manifest
 * @returns {{ selected: object | null, codeDefault: object | null, problems: string[] }}
 */
export function auditCloudVmProviderCoherence(env, manifest) {
  const rawProvider = (env.CMUX_VM_DEFAULT_PROVIDER ?? CODE_DEFAULT_PROVIDER).trim();
  if (rawProvider === SENSITIVE_PLACEHOLDER) {
    return {
      selected: null,
      codeDefault: null,
      problems: [
        "CMUX_VM_DEFAULT_PROVIDER is stored as a Sensitive env var, so its value " +
        "cannot be audited; store it as a plain env var (it is configuration, not a secret)",
      ],
    };
  }

  const selected = auditProviderReadiness(rawProvider, env, manifest);
  const problems = selected.problems.map((problem) => `default provider: ${problem}`);
  let codeDefault = null;
  if (rawProvider !== CODE_DEFAULT_PROVIDER) {
    codeDefault = auditProviderReadiness(CODE_DEFAULT_PROVIDER, env, manifest);
    problems.push(
      ...codeDefault.problems.map((problem) => `code default (${CODE_DEFAULT_PROVIDER}): ${problem}`),
    );
  }
  return { selected, codeDefault, problems };
}
