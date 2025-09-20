const LOCAL_HOSTS = new Set([
  "localhost",
  "127.0.0.1",
  "0.0.0.0",
  "::1",
]);

function isLikelyLocalHost(hostname: string): boolean {
  if (!hostname) return false;
  const lower = hostname.toLowerCase();
  if (LOCAL_HOSTS.has(lower)) return true;
  if (lower.endsWith(".localhost")) return true;
  if (lower.endsWith(".local")) return true;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(lower)) return true;
  return false;
}

export function normalizeOrigin(rawOrigin: string): string {
  const trimmed = rawOrigin?.trim();
  if (!trimmed) return rawOrigin;
  try {
    const url = new URL(trimmed);
    const isLocal = isLikelyLocalHost(url.hostname);
    if (url.protocol === "http:" && !isLocal) {
      url.protocol = "https:";
    }
    return url.origin;
  } catch (error) {
    console.warn(
      `[normalizeOrigin] Unable to parse origin: ${rawOrigin}`,
      error instanceof Error ? error.message : error
    );
    return trimmed;
  }
}
