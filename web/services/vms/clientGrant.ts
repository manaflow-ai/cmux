export const CLOUD_CLIENT_GRANT_ENV = "CMUX_CLOUD_REQUIRE_CLIENT_GRANT";
export const CLOUD_REMOTE_AUTH_METADATA_KEY = "cmuxRemoteAuth";
export type CloudRemoteAuthMode = "trusted-carrier" | "client-grant";

export function cloudClientGrantRequired(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return /^(1|true|yes|on)$/i.test(env[CLOUD_CLIENT_GRANT_ENV]?.trim() ?? "");
}

/** The immutable listener mode baked into a machine. Rows created before the
 * marker shipped are trusted-carrier compatibility machines. */
export function cloudRemoteAuthMode(
  metadata: Record<string, unknown> | null | undefined,
  fallback: CloudRemoteAuthMode = "trusted-carrier",
): CloudRemoteAuthMode {
  const value = metadata?.[CLOUD_REMOTE_AUTH_METADATA_KEY];
  return value === "client-grant" || value === "trusted-carrier" ? value : fallback;
}
