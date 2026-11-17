import Markdown from "react-markdown";
import rehypeRaw from "rehype-raw";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkGfm from "remark-gfm";
import { visit } from "unist-util-visit";
import type { Element, Root } from "hast";
import { type ListingKey, repositoryRawUrl, repositoryTreeUrl } from "./refs";

/**
 * A listing's README, rendered the way its repo shows it, but safely: raw HTML
 * goes through GitHub's sanitize schema (no scripts, styles, event handlers or
 * iframes), and relative links and images are rewritten to the repo at the
 * approved commit, so a page never shows anything newer than what was reviewed.
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

const schema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    img: [...(defaultSchema.attributes?.img ?? []), "align", "width", "height"],
    p: [...(defaultSchema.attributes?.p ?? []), "align"],
    div: [...(defaultSchema.attributes?.div ?? []), "align"],
    h1: [...(defaultSchema.attributes?.h1 ?? []), "align"],
  },
};

/** A rehype step, after sanitizing, that rewrites URLs and marks outbound links. */
function rehypeRepoUrls(source: ReadmeSource) {
  return () => (tree: Root) => {
    visit(tree, "element", (node: Element) => {
      const props = node.properties ?? {};
      if (node.tagName === "a" && typeof props.href === "string") {
        const href = rewriteReadmeUrl(source, props.href, "link");
        if (href === null) {
          delete props.href;
        } else {
          props.href = href;
          if (!href.startsWith("#")) props.rel = ["nofollow", "ugc", "noopener", "noreferrer"];
        }
      }
      if (node.tagName === "img") {
        const src = typeof props.src === "string" ? rewriteReadmeUrl(source, props.src, "image") : null;
        if (src === null) delete props.src;
        else props.src = src;
        props.loading = "lazy";
        props.decoding = "async";
        props.referrerPolicy = "no-referrer";
      }
    });
  };
}

export function Readme({ source, markdown }: { source: ReadmeSource; markdown: string }) {
  return (
    <div className="extension-readme">
      <Markdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[rehypeRaw, [rehypeSanitize, schema], rehypeRepoUrls(source)]}
        // URLs are checked by rehypeRepoUrls; keep react-markdown from rewriting them first.
        urlTransform={(url) => url}
      >
        {markdown}
      </Markdown>
    </div>
  );
}
