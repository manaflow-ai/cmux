// Links in the markdown editor: what a link points at, GitHub-style heading anchors, and the
// batched, cached existence check of relative targets (`cmux.markdown.resolveLinks`).
import type { Node as ProseNode } from "@milkdown/kit/prose/model";

/** What following a link does. */
export type LinkKind = "anchor" | "markdown" | "file" | "external" | "mail" | "unsafe";

export interface ParsedLink {
  kind: LinkKind;
  href: string;
  /** For relative links: the path part, decoded, without `#fragment` or `?query`. */
  path: string;
  /** The `#fragment`, decoded, without `#`; "" when none. */
  anchor: string;
}

const MARKDOWN_PATH = /\.(md|markdown|mdx|mdown|mkd)$/i;

function decode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/** Classifies an href as the page follows it. */
export function parseLink(raw: string): ParsedLink {
  const href = raw.trim();
  const hash = href.indexOf("#");
  const anchor = hash >= 0 ? decode(href.slice(hash + 1)) : "";
  if (href.startsWith("#")) return { kind: "anchor", href, path: "", anchor };
  if (/^(mailto|tel):/i.test(href)) return { kind: "mail", href, path: "", anchor: "" };
  if (/^https?:\/\//i.test(href) || href.startsWith("//")) return { kind: "external", href, path: "", anchor: "" };
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || !href) return { kind: "unsafe", href, path: "", anchor: "" };
  const path = decode(href.replace(/[?#].*$/, ""));
  return { kind: MARKDOWN_PATH.test(path) ? "markdown" : "file", href, path, anchor };
}

/**
 * GitHub's heading anchor (github-slugger): lowercase, punctuation removed except `-` and `_`,
 * spaces to `-`. Letters and digits of every script stay.
 */
export function githubSlug(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, "")
    .replace(/ /g, "-");
}

/** Slugs in document order, with GitHub's `-1`, `-2` suffixes for repeated headings. */
export class Slugger {
  private readonly seen = new Map<string, number>();

  slug(text: string): string {
    const base = githubSlug(text);
    let slug = base;
    while (this.seen.has(slug)) {
      const count = (this.seen.get(base) ?? 0) + 1;
      this.seen.set(base, count);
      slug = `${base}-${count}`;
    }
    this.seen.set(slug, 0);
    return slug;
  }
}

export interface HeadingTarget {
  slug: string;
  text: string;
  level: number;
  pos: number;
}

/** Every heading of a document with its GitHub anchor, in order. */
export function headingTargets(doc: ProseNode): HeadingTarget[] {
  const slugger = new Slugger();
  const out: HeadingTarget[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name !== "heading") return true;
    out.push({
      slug: slugger.slug(node.textContent),
      text: node.textContent,
      level: Number(node.attrs.level ?? 1),
      pos,
    });
    return false;
  });
  return out;
}

/** The heading an anchor names (exact slug, then case-insensitive), or undefined. */
export function findHeading(doc: ProseNode, anchor: string): HeadingTarget | undefined {
  const targets = headingTargets(doc);
  const wanted = anchor.trim();
  return (
    targets.find((target) => target.slug === wanted) ?? targets.find((target) => target.slug === githubSlug(wanted))
  );
}

/** The answer for one relative path of `cmux.markdown.resolveLinks`. */
export interface ResolvedLink {
  exists: boolean;
  /** The absolute path, when it exists (or would, inside the workspace). */
  path?: string;
  kind?: "markdown" | "file" | "directory";
}

export type ResolveLinks = (from: string, paths: string[]) => Promise<Record<string, ResolvedLink>>;

/**
 * Batches and caches existence checks: `request` collects paths, one host call per tick answers
 * them, and `get` reads the cache (undefined while pending). Cached per source file.
 */
export class LinkResolver {
  private readonly cache = new Map<string, ResolvedLink>();
  private readonly pending = new Set<string>();
  private from = "";
  private flush: Promise<void> | null = null;
  private generation = 0;

  constructor(
    private readonly resolve: ResolveLinks | null,
    private readonly onResolved: () => void,
  ) {}

  /** The file links are relative to. A new file clears the cache. */
  setFrom(from: string): void {
    if (from === this.from) return;
    this.from = from;
    this.cache.clear();
    this.pending.clear();
    this.generation++;
  }

  /** Forgets every answer (a file was created or deleted). */
  invalidate(): void {
    this.cache.clear();
    this.generation++;
  }

  get(path: string): ResolvedLink | undefined {
    return this.cache.get(path);
  }

  request(paths: Iterable<string>): void {
    if (!this.resolve) return;
    for (const path of paths) if (path && !this.cache.has(path)) this.pending.add(path);
    if (!this.pending.size || this.flush) return;
    this.flush = Promise.resolve().then(async () => {
      const batch = [...this.pending];
      this.pending.clear();
      const generation = this.generation;
      try {
        const answers = await this.resolve!(this.from, batch);
        if (generation !== this.generation) return;
        for (const path of batch) this.cache.set(path, answers?.[path] ?? { exists: false });
        this.onResolved();
      } catch {
        // No answer: the links stay unchecked (not shown broken).
      } finally {
        this.flush = null;
        if (this.pending.size) this.request([]);
      }
    });
  }
}

/** Relative link paths in a document (link marks and images), for `LinkResolver.request`. */
export function relativeLinkPaths(doc: ProseNode): Set<string> {
  const paths = new Set<string>();
  doc.descendants((node) => {
    for (const mark of node.marks) {
      if (mark.type.name !== "link") continue;
      const link = parseLink(String(mark.attrs.href ?? ""));
      if ((link.kind === "markdown" || link.kind === "file") && link.path) paths.add(link.path);
    }
    return true;
  });
  return paths;
}

/** The direct link URL a pasted text is, or null (one http(s) or mailto URL, nothing else). */
export function pastedURL(text: string): string | null {
  const value = text.trim();
  return /^(https?:\/\/|mailto:)[^\s<>"]+$/i.test(value) ? value : null;
}
