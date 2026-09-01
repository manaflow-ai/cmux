// Coherence check between the deployed Cloud VM env and the image manifest.
//
// The 2026-08-26 outage: code shipped assuming CMUX_VM_DEFAULT_PROVIDER=blaxel
// while production still said freestyle, and no BLAXEL_SANDBOX_IMAGE was set.
// Key-presence auditing could not catch that; provider VALUES have to agree
// with the manifest. Image env vars derive from manifest.json (each entry
// carries its provider and env var), so a new provider cannot be added
// without this audit learning about it.

/**
 * Provider API credential env keys. These cannot be derived from the manifest;
 * keep in sync with services/vms/drivers/*.
 */
const PROVIDER_CREDENTIAL_KEYS = {
  e2b: ["E2B_API_KEY"],
  freestyle: ["FREESTYLE_API_KEY"],
  daytona: ["DAYTONA_API_KEY"],
  blaxel: ["BL_API_KEY", "BL_WORKSPACE"],
};

// Mirrors defaultProviderId() in services/vms/drivers/index.ts. Shipped CLIs
// also hardcode this provider's image ids (cmux.swift cloudVMDesktopImage /
// cloudVMBaseImage), so it must stay provisionable in production even when
// the env deliberately selects a different default as a rollback.
export const CODE_DEFAULT_PROVIDER = "blaxel";

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
 * @returns {{ provider: string, envVar: string | null, image: string | null, problems: string[] }}
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

  const envVar = entries[0].envVar;
  const image = env[envVar]?.trim() || null;
  if (!image) {
    problems.push(
      `${envVar} is not set; deployed runtimes fail closed on imageless ` +
      `creates for provider ${provider}`,
    );
  } else if (image === SENSITIVE_PLACEHOLDER) {
    problems.push(
      `${envVar} is stored as a Sensitive env var, so its value cannot be audited; ` +
      "store it as a plain env var (image ids are configuration, not secrets)",
    );
  } else {
    const entry = entries.find((candidate) => candidate.imageId === image || candidate.version === image);
    if (!entry) {
      problems.push(
        `${envVar}=${image} is not listed in the image manifest for ${provider}; ` +
        "deployed runtimes will reject it with vm_image_config_error",
      );
    } else if (entry.validationStatus !== "passed") {
      problems.push(
        `${envVar} selects manifest entry ${entry.version} whose validationStatus is ` +
        `${entry.validationStatus}, not passed`,
      );
    }
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

  return { provider, envVar, image, problems };
}

/**
 * Full coherence audit. Two legs:
 * - the env-selected default provider (what imageless creates use), and
 * - the code default (blaxel) whenever the env selects something else,
 *   because shipped clients hardcode blaxel image ids: an env rollback to
 *   another default must not leave blaxel unprovisionable. This second leg
 *   is what would have caught the 2026-08-26 production env, where a fully
 *   coherent freestyle default coexisted with clients that only send blaxel.
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
