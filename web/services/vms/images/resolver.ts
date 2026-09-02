import type { ProviderId } from "../drivers";
import { allowUnmanifestedImages, type VmRuntimeEnv } from "../config";
import { VmImageConfigError, type VmImageSource } from "../errors";
import manifest from "./manifest.json";

/**
 * What a machine is for. Clients ask for a kind instead of pinning an image id so
 * the server (the checked-in manifest) stays the only place that knows concrete
 * image ids.
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
  /** Legacy: the env var that used to select this image. Nothing reads it any more. */
  readonly envVar: string;
  /** Legacy: local dev now uses the same `defaultForKind` entry as production. */
  readonly defaultForLocalDev?: boolean;
  /** Which machine kind this image serves. Missing means "base" unless the id says otherwise. */
  readonly kind?: VmImageKind;
  /** The image served for `kind` when the client does not name one. Exactly one per provider and kind. */
  readonly defaultForKind?: boolean;
  readonly cmuxdRemoteCommit: string;
  /** The cmux commit whose devbox definition produced this image. */
  readonly repoCommit?: string;
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

export function listVmImageManifestEntries(): readonly VmImageManifestEntry[] {
  return typedManifest.images;
}

/** Manifest image ids recorded for a provider; surfaced in config errors so operators see what is allowed. */
export function listVmImageIds(provider: ProviderId): string[] {
  return typedManifest.images
    .filter((entry) => entry.provider === provider)
    .map((entry) => entry.imageId);
}

/**
 * The manifest entry for an image id or version. One image can be listed
 * under more than one kind (a desktop image is a superset of a base one, so
 * the Freestyle devbox serves both); with a `kind`, the entry of that kind
 * wins, otherwise the first listing does.
 */
export function findVmImageManifestEntry(
  provider: ProviderId,
  image: string,
  kind?: VmImageKind,
): VmImageManifestEntry | null {
  const matches = typedManifest.images.filter((candidate) =>
    candidate.provider === provider &&
    (candidate.imageId === image || candidate.version === image)
  );
  if (kind !== undefined) {
    const ofKind = matches.find((candidate) => deriveVmImageKind(candidate, image) === kind);
    if (ofKind) return ofKind;
  }
  return matches[0] ?? null;
}

/** The manifest entry flagged `defaultForKind` for `kind`, if the provider has one. */
export function findVmImageKindDefault(provider: ProviderId, kind: VmImageKind): VmImageManifestEntry | null {
  return typedManifest.images.find((entry) =>
    entry.provider === provider && (entry.kind ?? "base") === kind && entry.defaultForKind === true
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
 * The image each kind would resolve to for `provider`.
 * Kinds with no manifest default are omitted, so clients can offer only kinds that work.
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

/**
 * The provider that owns an explicitly requested image, when the manifest
 * answers that unambiguously. Clients (the CLI since #10478) send provider
 * image ids without a provider field and rely on the deployment's default
 * provider matching; when the two disagree, the image is looked up under the
 * wrong provider and provisioning fails closed even though the image is a
 * known-good manifest entry (the 2026-08-26 outage). An image id or version
 * that appears under exactly one provider names that provider; anything
 * ambiguous or unknown returns null and leaves the caller's default in force.
 */
export function inferVmProviderForImage(requestedImage: string | undefined): ProviderId | null {
  const requested = requestedImage?.trim();
  if (!requested) return null;
  const providers = new Set(
    typedManifest.images
      .filter((entry) => entry.imageId === requested || entry.version === requested)
      .map((entry) => entry.provider),
  );
  if (providers.size !== 1) return null;
  return [...providers][0] ?? null;
}

/**
 * The checked-in manifest is the only source of truth for images; no env var
 * selects or overrides one. Resolution order:
 *  1. an explicit `requestedImage` (must be in the manifest unless unmanifested
 *     images are allowed, which they are outside deployed runtimes or with
 *     CMUX_VM_ALLOW_UNMANIFESTED_IMAGES=1);
 *  2. the manifest entry flagged `defaultForKind` for the requested kind
 *     (`base` when the client did not ask for a kind).
 * Rollback is a manifest change (revert the promotion PR) and a deploy.
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
    return resolveRequested(provider, requested, env, kind);
  }

  const effectiveKind = kind ?? "base";
  const kindDefault = findVmImageKindDefault(provider, effectiveKind);
  if (kindDefault) return selectionFromEntry(kindDefault);

  throw new VmImageConfigError({
    provider,
    kind: effectiveKind,
    source: "default",
    allowedImages: listVmImageIds(provider),
    reason: `no ${effectiveKind} image is recorded as the manifest default for ${provider}: promote one (bun run devbox:promote -- ${provider})`,
  });
}

function resolveRequested(
  provider: ProviderId,
  image: string,
  env: VmRuntimeEnv,
  kind: VmImageKind | undefined,
): VmImageSelection {
  const entry = findVmImageManifestEntry(provider, image, kind);
  if (entry) {
    const selection = selectionFromEntry(entry);
    if (kind !== undefined && selection.kind !== kind) {
      throw new VmImageConfigError({
        provider,
        image,
        kind,
        source: "request",
        allowedImages: listVmImageIds(provider),
        reason: `${image} is a ${selection.kind} image, not a ${kind} image`,
      });
    }
    return selection;
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
   * Client-safe details. Provider names, image ids, and manifest wording stay
   * out of responses (see `expectNoCloudVmImplementationLeaks` in
   * tests/vm-route-auth.test.ts); those go to the operator log instead.
   */
  readonly details: {
    /** True only when the client asked for a specific image; false for manifest-default failures. */
    readonly imageRequested: boolean;
    /** The kind the client asked for, when it asked by kind. */
    readonly kind?: string;
    /** Which configuration failed: the request body or the server's manifest default. */
    readonly source: VmImageSource;
    /** Kinds this deployment can serve right now, so a client can offer a working alternative. */
    readonly allowedKinds: readonly VmImageKind[];
  };
  /** What an operator needs to fix the deployment; logged, never returned to clients. */
  readonly operator: {
    readonly provider: ProviderId;
    readonly image?: string;
    readonly kind?: string;
    readonly source: VmImageSource;
    readonly allowedImages: readonly string[];
    readonly reason: string;
  };
};

/**
 * Shared wording and logging for `vm_image_config_error`, so create, base open,
 * and base reset describe the same failure the same way. Logs the operator
 * detail (provider, allowed image ids, reason) once per call.
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
    action = `Retry with a different \`kind\` (available: ${kindList}), or ask an admin to promote a ${err.kind} Cloud VM image.`;
  } else {
    message = "The default Cloud VM image is not configured in this environment.";
    action = "Ask an admin to promote a default Cloud VM image, then retry.";
  }
  const operator = {
    provider: err.provider,
    image: err.image,
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
