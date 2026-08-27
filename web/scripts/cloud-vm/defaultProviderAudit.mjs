// Coherence check between the deployed Cloud VM env and the image manifest.
//
// The 2026-08-26 outage: code shipped assuming CMUX_VM_DEFAULT_PROVIDER=blaxel
// while production still said freestyle, and no BLAXEL_SANDBOX_IMAGE was set.
// Key-presence auditing could not catch that; the default provider's VALUE has
// to agree with the manifest. Everything here derives from manifest.json (each
// entry carries its provider and env var), so a new provider cannot be added
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

// Mirrors defaultProviderId() in services/vms/drivers/index.ts.
const CODE_DEFAULT_PROVIDER = "blaxel";

/**
 * @param {Record<string, string | undefined>} env deployed runtime env values
 * @param {{ images: Array<{ provider: string, version: string, imageId: string, envVar: string, validationStatus: string }> }} manifest
 * @returns {{ provider: string, envVar: string | null, image: string | null, problems: string[] }}
 */
// What `vercel env pull` writes for values it cannot decrypt. The default
// provider and its image id are configuration, not secrets; stored as
// Sensitive they become unauditable, which defeats this check.
const SENSITIVE_PLACEHOLDER = "[SENSITIVE]";

export function auditDefaultProviderImage(env, manifest) {
  const problems = [];
  const rawProvider = (env.CMUX_VM_DEFAULT_PROVIDER ?? CODE_DEFAULT_PROVIDER).trim();
  if (rawProvider === SENSITIVE_PLACEHOLDER) {
    problems.push(
      "CMUX_VM_DEFAULT_PROVIDER is stored as a Sensitive env var, so its value " +
      "cannot be audited; store it as a plain env var (it is configuration, not a secret)",
    );
    return { provider: null, envVar: null, image: null, problems };
  }
  const provider = rawProvider;
  const entries = manifest.images.filter((entry) => entry.provider === provider);
  if (entries.length === 0) {
    problems.push(
      `default provider ${provider} has no entries in the image manifest; ` +
      "every imageless create will fail closed in deployed runtimes",
    );
    return { provider, envVar: null, image: null, problems };
  }

  const envVar = entries[0].envVar;
  const image = env[envVar]?.trim() || null;
  if (!image) {
    problems.push(
      `${envVar} is not set; deployed runtimes fail closed on imageless creates ` +
      `for default provider ${provider}`,
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

  for (const key of PROVIDER_CREDENTIAL_KEYS[provider] ?? []) {
    if (!env[key]?.trim()) {
      problems.push(`${key} is not set but ${provider} is the default provider`);
    }
  }

  return { provider, envVar, image, problems };
}
