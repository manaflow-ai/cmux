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

/** Joins a repo-relative URL onto the listing's directory; a leading `/` means the repo root. */
function repoRelativePath(source: ReadmeSource, href: string): string | null {
  const [pathPart] = href.split(/[?#]/, 1);
  if (!pathPart) return null;
  const rootRelative = pathPart.startsWith("/");
  const parts = rootRelative || !source.path ? [] : source.path.split("/");
  for (const segment of pathPart.split("/")) {
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
  if (kind === "image") return repositoryRawUrl(root, source.commit, resolved);
  const hash = value.includes("#") ? value.slice(value.indexOf("#")) : "";
  const isDirectory = resolved === "" || DIRECTORY_HINT.test(value.split(/[?#]/, 1)[0]!);
  return `${repositoryTreeUrl(root, source.commit, resolved, isDirectory ? "tree" : "blob")}${hash}`;
}

export function Readme({ source, markdown }: { source: ReadmeSource; markdown: string }) {
  return (
    <div className="extension-readme">
      <Markdown source={markdown} url={(href, kind) => rewriteReadmeUrl(source, href, kind)} />
    </div>
  );
}
