export const CLOUD_CLIENT_GRANT_ENV = "CMUX_CLOUD_REQUIRE_CLIENT_GRANT";

export function cloudClientGrantRequired(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return /^(1|true|yes|on)$/i.test(env[CLOUD_CLIENT_GRANT_ENV]?.trim() ?? "");
}
