/** Proxy policy uses exact HTTPS origins, never suffix or wildcard matching. */
export const httpsOrigin = (value: string): string | null => {
  if (value.length > 2048 || !/^https:\/\/[^/?#\\]+\/?$/iu.test(value)
    || Array.from(value).some((character) => character.charCodeAt(0) <= 32 || character.charCodeAt(0) === 127)) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash && url.pathname === "/"
      ? url.origin
      : null;
  } catch {
    return null;
  }
};

/** A malformed deployment policy disables proxy destinations. */
export const parseHttpsProxyOrigins = (value: string | undefined): ReadonlyArray<string> => {
  if (value === undefined) return [];
  try {
    const parsed: unknown = JSON.parse(value);
    if (!Array.isArray(parsed) || parsed.length > 64) return [];
    const origins: string[] = [];
    for (const item of parsed) {
      if (typeof item !== "string") return [];
      const origin = httpsOrigin(item);
      if (origin === null) return [];
      origins.push(origin);
    }
    return [...new Set(origins)];
  } catch {
    return [];
  }
};
