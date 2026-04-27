import type { ProviderId } from "../drivers";
import { allowUnmanifestedImages, isDeployedRuntime, type VmRuntimeEnv } from "../config";
import { VmImageConfigError } from "../errors";
import manifest from "./manifest.json";

export type VmImageManifestEntry = {
  readonly provider: ProviderId;
  readonly version: string;
  readonly imageId: string;
  readonly envVar: string;
  readonly defaultForLocalDev?: boolean;
  readonly cmuxdRemoteCommit: string;
  readonly builtAt: string;
  readonly builderScriptVersion: string;
  readonly validationStatus: "passed" | "failed" | "unknown";
  readonly notes?: string;
};

export type VmImageSelection = {
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly manifestEntry: VmImageManifestEntry | null;
};

const typedManifest = manifest as {
  readonly schemaVersion: number;
  readonly images: readonly VmImageManifestEntry[];
};

export function providerImageEnvKey(provider: ProviderId): string {
  switch (provider) {
    case "e2b":
      return "E2B_CMUXD_WS_TEMPLATE";
    case "freestyle":
      return "FREESTYLE_SANDBOX_SNAPSHOT";
    default:
      return assertNever(provider);
  }
}

export function listVmImageManifestEntries(): readonly VmImageManifestEntry[] {
  return typedManifest.images;
}

export function resolveVmImage(
  provider: ProviderId,
  requestedImage: string | undefined,
  env: VmRuntimeEnv = process.env,
): VmImageSelection {
  const requested = requestedImage?.trim();
  if (requested) {
    return resolveKnownOrAllowed(provider, requested, undefined, env);
  }

  const envVar = providerImageEnvKey(provider);
  const configured = env[envVar]?.trim();
  if (configured) {
    return resolveKnownOrAllowed(provider, configured, envVar, env);
  }

  if (isDeployedRuntime(env)) {
    throw new VmImageConfigError({
      provider,
      envVar,
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
      reason: `no local default image is recorded for ${provider}`,
    });
  }
  return selectionFromEntry(localDefault);
}

function resolveKnownOrAllowed(
  provider: ProviderId,
  image: string,
  envVar: string | undefined,
  env: VmRuntimeEnv,
): VmImageSelection {
  const entry = typedManifest.images.find((candidate) =>
    candidate.provider === provider &&
    (candidate.imageId === image || candidate.version === image)
  );
  if (entry) return selectionFromEntry(entry);

  if (allowUnmanifestedImages(env)) {
    return {
      provider,
      image,
      imageVersion: null,
      manifestEntry: null,
    };
  }

  throw new VmImageConfigError({
    provider,
    image,
    envVar,
    reason: `${image} is not listed in the Cloud VM image manifest`,
  });
}

function selectionFromEntry(entry: VmImageManifestEntry): VmImageSelection {
  return {
    provider: entry.provider,
    image: entry.imageId,
    imageVersion: entry.version,
    manifestEntry: entry,
  };
}

function assertNever(value: never): never {
  throw new Error(`unsupported VM provider: ${String(value)}`);
}
