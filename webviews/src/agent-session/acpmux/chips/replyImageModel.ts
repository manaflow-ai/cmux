import { DataUrlCache, IMAGE_CACHE_MAX_CHARS, IMAGE_CACHE_MAX_ENTRIES } from "./imageCache";
import { type ReplyPolicy } from "./linkStore";
import { isTemplatePath, linkPath } from "./paths";

/// A local image: an absolute path, a `file://` URL or a relative path (from the session's folder).
export function localImageSource(src: string): string | undefined {
  if (isTemplatePath(src)) return undefined;
  const path = linkPath(src);
  if (path) return path;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(src) || src.startsWith("//") || src.startsWith("#") || src.startsWith("?"))
    return undefined;
  return src.split(/[?#]/)[0] || undefined;
}

/// The https image's site, or undefined for anything else.
export function remoteImageHost(src: string): string | undefined {
  try {
    const url = new URL(src);
    return url.protocol === "https:" && !url.username && !url.password ? url.host : undefined;
  } catch {
    return undefined;
  }
}

/// Whether the web image at `src` loads without a click under `click`: it is written exactly
/// `https://<a host the host named>/…` (lowercase, no port, user info, backslash or space before
/// the path), the same test the host makes on the same string, so the two never disagree.
export function loadsWithoutClick(src: string, policy: ReplyPolicy): boolean {
  if (policy.remoteImages !== "click" || !Array.isArray(policy.clickFreeImageHosts)) return false;
  return policy.clickFreeImageHosts.some((host) => typeof host === "string" && src.startsWith(`https://${host}/`));
}

/// Sources an automatic load started for, so a render twice in a row asks the host once.
export const started = new Set<string>();
/// Images that loaded on their own (a file in the folders, a web image under "always"), the most
/// recently drawn first. One it forgets loads again on its own when it draws.
export const loaded = new DataUrlCache(IMAGE_CACHE_MAX_ENTRIES, IMAGE_CACHE_MAX_CHARS, (src) => started.delete(src));
/// Images the reader loaded with "Load image". They stay: loading one again would need another
/// click (the host spends a gesture on each), so forgetting it would leave its placeholder.
export const clicked = new Map<string, string>();

/// The data URL a local or web image already loaded to, if it has (the image viewer steps to it).
export const loadedImageSrc = (src: string): string | undefined => clicked.get(src) ?? loaded.get(src);

/// Instances waiting on a load another instance of the same source started (the transcript's tile and
/// the Gallery's, say): they hear when it ends, since `started` keeps them from asking the host again.
/// Kept here with `started`, so a hot swap of ReplyImage.tsx keeps the waiters an in-flight load wakes.
export const waiting = new Map<string, Set<() => void>>();
export const loadEnded = (src: string) => {
  // Waiters stay until they unmount or show the image: one that wakes to a failed load may find
  // another instance already retrying, and must hear that retry end too.
  waiting.get(src)?.forEach((wake) => wake());
};
