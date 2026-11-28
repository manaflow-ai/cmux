/**
 * The raw-file hosts the registry builds media URLs on (cmux-platform Ref.ts rawUrl). The OG card fetches only
 * these, so a listing's URL can never point the cmux.com server at a private or loopback address.
 */
const MEDIA_HOSTS = new Set(["raw.githubusercontent.com", "gitlab.com", "codeberg.org"]);

/** Whether the server may fetch this URL: https on the default port, no credentials, on a registry media host. */
export function isMediaUrl(raw: string): boolean {
  try {
    const url = new URL(raw);
    return url.protocol === "https:" && url.port === "" && !url.username && !url.password && MEDIA_HOSTS.has(url.hostname);
  } catch {
    return false;
  }
}
