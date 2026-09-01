// Verbose-diagnostics flag for the App Review account.
//
// When the signed-in account's Stack `clientReadOnlyMetadata` carries
// `cmuxVerboseDiagnostics: true`, backend request handling emits a structured
// `[cmux-verbose-diag]` log line per authenticated request
// (services/observability/verboseDiagnostics.ts) and the iOS app streams its
// privacy-safe diagnostic events to `/api/diagnostics/ingest`. The flag is
// server-writable only; clients read it off the session payload at sign-in
// (`CMUXAuthUser.verboseDiagnosticsEnabled`) and on revalidation. This module
// owns the server-side write, mirroring services/account/reviewDemoContent.ts:
// preserve every other key and set or remove only ours. Set the flag with
// `bun scripts/set-verbose-diagnostics.ts <email> on|off`.

export const VERBOSE_DIAGNOSTICS_METADATA_KEY = "cmuxVerboseDiagnostics";

// Mirrors Stack's ReadonlyJson so `user.update` stays assignable.
export type VerboseDiagnosticsJson =
  | null
  | boolean
  | number
  | string
  | readonly VerboseDiagnosticsJson[]
  | { readonly [key: string]: VerboseDiagnosticsJson };

export type VerboseDiagnosticsUser = {
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: VerboseDiagnosticsJson;
  }): Promise<unknown>;
};

/**
 * Whether a metadata snapshot currently enables verbose diagnostics. Only the
 * literal boolean `true` counts, matching the client's fail-closed parse: a
 * malformed metadata write ("true", 1, {…}) never turns diagnostics on.
 */
export function verboseDiagnosticsEnabled(raw: unknown): boolean {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
  return (
    (raw as Record<string, unknown>)[VERBOSE_DIAGNOSTICS_METADATA_KEY] === true
  );
}

/**
 * Returns the metadata object with the verbose-diagnostics flag applied: set
 * to the literal `true` when enabling, removed entirely when disabling (every
 * non-`true` shape reads as off, so no tombstone value is needed). Every other
 * key is preserved verbatim.
 */
export function metadataApplyingVerboseDiagnostics(
  raw: unknown,
  enabled: boolean,
): Record<string, unknown> {
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  if (enabled) {
    metadata[VERBOSE_DIAGNOSTICS_METADATA_KEY] = true;
  } else {
    delete metadata[VERBOSE_DIAGNOSTICS_METADATA_KEY];
  }
  return metadata;
}

/**
 * Sets or clears the verbose-diagnostics flag on a Stack user, skipping the
 * write when the flag already has the requested value. Returns the metadata
 * snapshot that is now current.
 */
export async function setVerboseDiagnostics(
  user: VerboseDiagnosticsUser,
  enabled: boolean,
): Promise<Record<string, unknown>> {
  if (verboseDiagnosticsEnabled(user.clientReadOnlyMetadata) === enabled) {
    return metadataApplyingVerboseDiagnostics(
      user.clientReadOnlyMetadata,
      enabled,
    );
  }
  const next = metadataApplyingVerboseDiagnostics(
    user.clientReadOnlyMetadata,
    enabled,
  );
  await user.update({
    clientReadOnlyMetadata: next as VerboseDiagnosticsJson,
  });
  return next;
}
