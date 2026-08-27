import type { ProviderId } from "../drivers";
import { allowUnmanifestedImages, isDeployedRuntime, type VmRuntimeEnv } from "../config";
import { VmImageConfigError, type VmImageSource } from "../errors";
import manifest from "./manifest.json";

/**
 * What a machine is for. Clients ask for a kind instead of pinning an image id so
 * the server (env + manifest) stays the only place that knows concrete image ids.
 */
export type VmImageKind = "desktop" | "base";

export const VM_IMAGE_KINDS: readonly VmImageKind[] = ["desktop", "base"];

export function isVmImageKind(value: unknown): value is VmImageKind {
  return typeof value === "string" && (VM_IMAGE_KINDS as readonly string[]).includes(value);
}

export type VmImageManifestEntry = {
  readonly provider: ProviderId;
  readonly version: string;
  readonly imageId: string;
  readonly envVar: string;
  readonly defaultForLocalDev?: boolean;
  /** Which machine kind this image serves. Missing means "base" unless the id says otherwise. */
  readonly kind?: VmImageKind;
  /** The manifest default for `kind` when neither the client nor the env picks an image. */
  readonly defaultForKind?: boolean;
  readonly features?: {
    readonly bakedFreestyleSignedAdmin?: boolean;
  };
  readonly cmuxdRemoteCommit: string;
  readonly builtAt: string;
  readonly builderScriptVersion: string;
  readonly agentToolResolvedVersions?: Record<string, string>;
  readonly validationStatus: "passed" | "failed" | "unknown";
  readonly notes?: string;
};

export type VmImageSelection = {
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly manifestEntry: VmImageManifestEntry | null;
  readonly kind: VmImageKind;
};

export type VmImageResolveOptions = {
  readonly kind?: VmImageKind;
};

const typedManifest = manifest as {
  readonly schemaVersion: number;
  readonly images: readonly VmImageManifestEntry[];
};

/**
 * Env var that selects the provider's image. Desktop images get their own
 * `_DESKTOP_IMAGE` selector (today only blaxel ships desktop images); providers
 * with a single template/snapshot variable use it for both kinds.
 */
export function providerImageEnvKey(provider: ProviderId, kind?: VmImageKind): string {
  const baseKey = providerBaseImageEnvKey(provider);
  if (kind === "desktop" && baseKey.endsWith("_IMAGE")) {
    return `${baseKey.slice(0, -"_IMAGE".length)}_DESKTOP_IMAGE`;
  }
  return baseKey;
}

function providerBaseImageEnvKey(provider: ProviderId): string {
  switch (provider) {
    case "e2b":
      return "E2B_CMUXD_WS_TEMPLATE";
    case "freestyle":
      return "FREESTYLE_SANDBOX_SNAPSHOT";
    case "daytona":
      return "DAYTONA_SANDBOX_SNAPSHOT";
    case "blaxel":
      return "BLAXEL_SANDBOX_IMAGE";
    default:
      return assertNever(provider);
  }
}

export function listVmImageManifestEntries(): readonly VmImageManifestEntry[] {
  return typedManifest.images;
}

/** Manifest image ids recorded for a provider; surfaced in config errors so operators see what is allowed. */
export function listVmImageIds(provider: ProviderId): string[] {
  return typedManifest.images
    .filter((entry) => entry.provider === provider)
    .map((entry) => entry.imageId);
}

export function findVmImageManifestEntry(provider: ProviderId, image: string): VmImageManifestEntry | null {
  return typedManifest.images.find((candidate) =>
    candidate.provider === provider &&
    (candidate.imageId === image || candidate.version === image)
  ) ?? null;
}

/**
 * Kind of an image: the manifest entry's declared kind, else a name heuristic
 * (`xfce` / `devbox` images carry a desktop), else `base`.
 */
export function deriveVmImageKind(entry: VmImageManifestEntry | null, image: string): VmImageKind {
  if (entry?.kind) return entry.kind;
  return /xfce|devbox/i.test(image) ? "desktop" : "base";
}

/** Kind for an image id as stored on a VM row (manifest entry when known, else the name heuristic). */
export function vmImageKindFor(provider: ProviderId, image: string): VmImageKind {
  return deriveVmImageKind(findVmImageManifestEntry(provider, image), image);
}

/**
 * The image each kind would resolve to for `provider` in this environment.
 * Kinds with nothing configured are omitted, so clients can offer only kinds that work.
 */
export function listVmImageKinds(
  provider: ProviderId,
  env: VmRuntimeEnv = process.env,
): Array<{ kind: VmImageKind; image: string }> {
  const kinds: Array<{ kind: VmImageKind; image: string }> = [];
  for (const kind of VM_IMAGE_KINDS) {
    try {
      const selection = resolveVmImage(provider, undefined, env, { kind });
      kinds.push({ kind, image: selection.image });
    } catch (err) {
      if (err instanceof VmImageConfigError) continue;
      throw err;
    }
  }
  return kinds;
}

export function imageUsesBakedFreestyleSignedAdmin(provider: ProviderId, imageId: string): boolean {
  const entry = typedManifest.images.find((candidate) =>
    candidate.provider === provider && candidate.imageId === imageId
  );
  return entry?.features?.bakedFreestyleSignedAdmin === true;
}

/**
 * Resolution order:
 *  1. an explicit `requestedImage` (must be in the manifest unless unmanifested images are allowed);
 *  2. the provider's env selector for `kind` (operator configuration, accepted even when unmanifested);
 *     for `desktop`, the provider's generic selector also counts when it names a desktop image;
 *  3. with a `kind`: the manifest entry flagged `defaultForKind` for that kind (also in deployed runtimes);
 *  4. without a `kind`: deployed runtimes throw; local dev falls back to `defaultForLocalDev`.
 */
export function resolveVmImage(
  provider: ProviderId,
  requestedImage: string | undefined,
  env: VmRuntimeEnv = process.env,
  options: VmImageResolveOptions = {},
): VmImageSelection {
  const kind = options.kind;
  if (kind !== undefined && !isVmImageKind(kind)) {
    throw new VmImageConfigError({
      provider,
      kind: String(kind),
      source: "request",
      allowedImages: listVmImageIds(provider),
      reason: `unknown image kind ${String(kind)}; expected one of ${VM_IMAGE_KINDS.join(", ")}`,
    });
  }

  const requested = requestedImage?.trim();
  if (requested) {
    return resolveKnownOrAllowed(provider, requested, undefined, env, kind);
  }

  const envVar = providerImageEnvKey(provider, kind);
  const configured = env[envVar]?.trim();
  if (configured) {
    return resolveKnownOrAllowed(provider, configured, envVar, env, kind);
  }

  if (kind !== undefined) {
    return resolveByKind(provider, kind, envVar, env);
  }

  if (isDeployedRuntime(env)) {
    throw new VmImageConfigError({
      provider,
      envVar,
      source: "env",
      allowedImages: listVmImageIds(provider),
      reason: `${envVar} is required in deployed environments`,
    });
  }

  const localDefault = typedManifest.images.find((entry) =>
    entry.provider === provider && entry.defaultForLocalDev === true
  );
  if (!localDefault) {
    throw new VmImageConfigError({
      provider,
      envVar,
      source: "default",
      allowedImages: listVmImageIds(provider),
      reason: `no local default image is recorded for ${provider}`,
    });
  }
  return selectionFromEntry(localDefault);
}

function resolveByKind(
  provider: ProviderId,
  kind: VmImageKind,
  envVar: string,
  env: VmRuntimeEnv,
): VmImageSelection {
  // The kind-specific selector is unset. The provider's generic selector still
  // counts when the image it names is of the requested kind (e.g. a deployment
  // whose BLAXEL_SANDBOX_IMAGE already names a desktop image).
  const genericEnvVar = providerImageEnvKey(provider);
  if (genericEnvVar !== envVar) {
    const generic = env[genericEnvVar]?.trim();
    if (generic) {
      const entry = findVmImageManifestEntry(provider, generic);
      if (entry && deriveVmImageKind(entry, generic) === kind) {
        return selectionFromEntry(entry);
      }
    }
  }

  const kindDefault = typedManifest.images.find((entry) =>
    entry.provider === provider && entry.kind === kind && entry.defaultForKind === true
  );
  if (kindDefault) return selectionFromEntry(kindDefault);

  if (!isDeployedRuntime(env)) {
    const localDefault = typedManifest.images.find((entry) =>
      entry.provider === provider && entry.defaultForLocalDev === true
    );
    if (localDefault && deriveVmImageKind(localDefault, localDefault.imageId) === kind) {
      return selectionFromEntry(localDefault);
    }
  }

  throw new VmImageConfigError({
    provider,
    envVar,
    kind,
    source: "default",
    allowedImages: listVmImageIds(provider),
    reason: `no ${kind} image is configured for ${provider}: set ${envVar} or record a ${kind} manifest default`,
  });
}

const warnedUnmanifestedEnvImages = new Set<string>();

function resolveKnownOrAllowed(
  provider: ProviderId,
  image: string,
  envVar: string | undefined,
  env: VmRuntimeEnv,
  kind: VmImageKind | undefined,
): VmImageSelection {
  const entry = findVmImageManifestEntry(provider, image);
  if (entry) {
    const selection = selectionFromEntry(entry);
    if (kind !== undefined && selection.kind !== kind) {
      throw new VmImageConfigError({
        provider,
        image,
        envVar,
        kind,
        source: envVar === undefined ? "request" : "env",
        allowedImages: listVmImageIds(provider),
        reason: `${image} is a ${selection.kind} image, not a ${kind} image`,
      });
    }
    return selection;
  }

  // An image named by the provider's env var is operator configuration: the
  // manifest may lag behind a deployment, and refusing every create until the
  // manifest catches up is worse than running the configured image. Only a
  // client-requested image keeps the strict manifest check.
  if (envVar !== undefined) {
    const warnKey = `${provider}:${envVar}:${image}`;
    if (!warnedUnmanifestedEnvImages.has(warnKey)) {
      warnedUnmanifestedEnvImages.add(warnKey);
      console.warn(
        `[vm-image-resolver] ${envVar}=${image} is not listed in the Cloud VM image manifest for ${provider}; using it as configured (imageVersion unknown)`,
      );
    }
    return { provider, image, imageVersion: null, manifestEntry: null, kind: kind ?? deriveVmImageKind(null, image) };
  }

  if (allowUnmanifestedImages(env)) {
    return {
      provider,
      image,
      imageVersion: null,
      manifestEntry: null,
      kind: kind ?? deriveVmImageKind(null, image),
    };
  }

  throw new VmImageConfigError({
    provider,
    image,
    envVar,
    kind,
    source: "request",
    allowedImages: listVmImageIds(provider),
    reason: `${image} is not listed in the Cloud VM image manifest`,
  });
}

export type VmImageConfigErrorReport = {
  readonly message: string;
  readonly action: string;
  /**
   * Client-safe details. Provider names, env var names, image ids, and manifest
   * wording stay out of responses (see `expectNoCloudVmImplementationLeaks` in
   * tests/vm-route-auth.test.ts); those go to the operator log instead.
   */
  readonly details: {
    /** True only when the client asked for a specific image; false for env/manifest failures. */
    readonly imageRequested: boolean;
    /** The kind the client asked for, when it asked by kind. */
    readonly kind?: string;
    /** Which configuration failed: the request body, an env selector, or the server's default selection. */
    readonly source: VmImageSource;
    /** Kinds this environment can serve right now, so a client can offer a working alternative. */
    readonly allowedKinds: readonly VmImageKind[];
  };
  /** What an operator needs to fix the deployment; logged, never returned to clients. */
  readonly operator: {
    readonly provider: ProviderId;
    readonly image?: string;
    readonly envVar?: string;
    readonly kind?: string;
    readonly source: VmImageSource;
    readonly allowedImages: readonly string[];
    readonly reason: string;
  };
};

/**
 * Shared wording and logging for `vm_image_config_error`, so create, base open,
 * and base reset describe the same failure the same way. Logs the operator
 * detail (provider, env var, allowed image ids, reason) once per call.
 */
export function reportVmImageConfigError(
  err: VmImageConfigError,
  env: VmRuntimeEnv = process.env,
): VmImageConfigErrorReport {
  const imageRequested = err.source === "request" && err.image !== undefined;
  const allowedKinds = listVmImageKinds(err.provider, env).map((entry) => entry.kind);
  const kindList = allowedKinds.length > 0 ? allowedKinds.join(", ") : "none";
  let message: string;
  let action: string;
  if (imageRequested) {
    message = "The requested Cloud VM image is not available in this environment.";
    action = `Retry without \`image\` to use the default Cloud VM image (or pass \`kind\`: ${kindList}), or ask an admin for a supported image id.`;
  } else if (err.source === "request" && err.kind !== undefined) {
    message = `Cloud VM image kind "${err.kind}" is not supported.`;
    action = `Pass \`kind\` as one of ${VM_IMAGE_KINDS.join(", ")}, or omit it to use the default Cloud VM image.`;
  } else if (err.kind !== undefined) {
    message = `No ${err.kind} Cloud VM image is available in this environment.`;
    action = `Retry with a different \`kind\` (available: ${kindList}), or ask an admin to configure a ${err.kind} Cloud VM image.`;
  } else {
    message = "The default Cloud VM image is not configured in this environment.";
    action = "Ask an admin to configure the default Cloud VM image, then retry.";
  }
  const operator = {
    provider: err.provider,
    image: err.image,
    envVar: err.envVar,
    kind: err.kind,
    source: err.source,
    allowedImages: err.allowedImages,
    reason: err.reason,
  };
  console.error("[vm-image-config-error]", JSON.stringify(operator));
  return {
    message,
    action,
    details: { imageRequested, kind: err.kind, source: err.source, allowedKinds },
    operator,
  };
}

function selectionFromEntry(entry: VmImageManifestEntry): VmImageSelection {
  return {
    provider: entry.provider,
    image: entry.imageId,
    imageVersion: entry.version,
    manifestEntry: entry,
    kind: deriveVmImageKind(entry, entry.imageId),
  };
}

function assertNever(value: never): never {
  throw new Error(`unsupported VM provider: ${String(value)}`);
}
