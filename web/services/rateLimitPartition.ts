export function rateLimitDeploymentPartition(
  runtimeEnvironment: NodeJS.ProcessEnv = process.env,
): string {
  const raw = runtimeEnvironment.VERCEL_ENV
    ?? runtimeEnvironment.NODE_ENV
    ?? "development";
  const normalized = raw.trim().toLowerCase();
  return /^[a-z0-9._-]{1,64}$/u.test(normalized)
    ? normalized
    : "unknown";
}
