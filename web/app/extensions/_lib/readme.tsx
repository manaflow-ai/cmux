import { Markdown } from "./markdown";
import { type ListingKey, repositoryRawUrl, repositoryTreeUrl } from "./refs";

/**
 * A listing's README, rendered the way its repo shows it, but safely: markdown.tsx builds
 * React elements and keeps only a short list of HTML tags and attributes (no scripts,
 * styles, event handlers or iframes), and relative links and images are rewritten to the
 * repo at the approved commit, so a page never shows anything newer than what was reviewed.
 */

export type ReadmeSource = ListingKey & { commit: string };

const SAFE_PROTOCOLS = new Set(["http:", "https:", "mailto:"]);
// A trailing slash names a folder; anything else is a file (GitHub redirects a blob URL of a folder to its tree).
const DIRECTORY_HINT = /\/$/;

/** A path segment with its percent-escapes decoded once (the URL builders encode it again), or null when it cannot be one segment. */
function decodeSegment(segment: string): string | null {
  try {
    const decoded = decodeURIComponent(segment);
    return decoded.includes("/") || decoded.includes("\\") ? null : decoded;
  } catch {
    return null;
  }
}

/** Joins a repo-relative URL onto the listing's directory; a leading `/` means the repo root. */
function repoRelativePath(source: ReadmeSource, href: string): string | null {
  const [pathPart] = href.split(/[?#]/, 1);
  if (!pathPart) return null;
  const rootRelative = pathPart.startsWith("/");
  const parts = rootRelative || !source.path ? [] : source.path.split("/");
  for (const raw of pathPart.split("/")) {
    // Decoded before the checks, so an encoded "%2e%2e" climbs (and is refused) like "..".
    const segment = decodeSegment(raw);
    if (segment === null) return null;
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (parts.length === 0) return null;
      parts.pop();
    } else {
      parts.push(segment);
    }
  }
  return parts.join("/");
}

/**
 * Where a README URL points on the page: absolute http(s)/mailto URLs and
 * in-page anchors stay; a relative URL resolves against the repo at `commit`
 * (raw file for images, tree/blob for links); anything else (javascript:,
 * data:, a path that climbs out of the repo) is dropped.
 */
export function rewriteReadmeUrl(source: ReadmeSource, href: string, kind: "link" | "image"): string | null {
  const value = href.trim();
  if (!value) return null;
  if (value.startsWith("#")) return kind === "link" ? value : null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith("//")) {
    try {
      const url = new URL(value.startsWith("//") ? `https:${value}` : value);
      if (!SAFE_PROTOCOLS.has(url.protocol)) return null;
      if (kind === "image" && url.protocol !== "https:") return null;
      return url.toString();
    } catch {
      return null;
    }
  }
  const resolved = repoRelativePath(source, value);
  if (resolved === null) return null;
  // The path is resolved against the repo root here; the URL builders add the listing path, so pass it from the root.
  const root: ReadmeSource = { ...source, path: "" };
  // The query and fragment are kept as written (e.g. `?plain=1`, `?sanitize=true`, `#usage`).
  const suffix = value.slice(value.split(/[?#]/, 1)[0]!.length);
  if (kind === "image") {
    // A host with no known raw route has no image URL: the image is dropped, never drawn from "null...".
    const raw = repositoryRawUrl(root, source.commit, resolved);
    return raw === null ? null : `${raw}${suffix}`;
  }
  const isDirectory = resolved === "" || DIRECTORY_HINT.test(value.split(/[?#]/, 1)[0]!);
  return `${repositoryTreeUrl(root, source.commit, resolved, isDirectory ? "tree" : "blob")}${suffix}`;
}

export function Readme({ source, markdown }: { source: ReadmeSource; markdown: string }) {
  return (
    <div className="extension-readme">
      <Markdown source={markdown} url={(href, kind) => rewriteReadmeUrl(source, href, kind)} />
    </div>
  );
}
