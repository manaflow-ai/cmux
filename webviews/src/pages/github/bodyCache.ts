// A pull request's or issue's body is parsed once per text, not once per mount. Leaving the GitHub
// page for another pull request and coming back (or an issue list redrawing its rows) mounts every
// body again, and each mount lexed its Markdown or parsed its HTML from scratch, though the text was
// the same. These keep the last few hundred results by their text, most recent last, the way
// TanStack Query keeps a query's data past its last observer (gcTime) so a revisit draws from the
// cache. Both results are only read after they are made (GitHubMarkdown.tsx draws marked's tokens;
// React elements are immutable), so one result can serve every mount.
import { lexer, type Token } from "marked";
import type { ReactNode } from "react";

/// The bound on both entries and characters held: a body past the character bound is parsed and not
/// kept, so one huge body cannot push the rest out or grow the page.
export const BODY_CACHE_ENTRIES = 256;
export const BODY_CACHE_CHARS = 2_000_000;

export class BodyCache<V> {
  private readonly entries = new Map<string, V>();
  private chars = 0;

  constructor(
    private readonly maxEntries = BODY_CACHE_ENTRIES,
    private readonly maxChars = BODY_CACHE_CHARS,
  ) {}

  get size(): number {
    return this.entries.size;
  }

  read(key: string, make: (key: string) => V): V {
    const held = this.entries.get(key);
    if (held !== undefined) {
      this.entries.delete(key);
      this.entries.set(key, held);
      return held;
    }
    const made = make(key);
    if (key.length > this.maxChars) return made;
    this.entries.set(key, made);
    this.chars += key.length;
    while (this.entries.size > this.maxEntries || this.chars > this.maxChars) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
      this.chars -= oldest.length;
    }
    return made;
  }
}

const lexed = new BodyCache<Token[]>();

/** marked's GitHub-flavored tokens for `source`, lexed once per text. */
export function bodyTokens(source: string): Token[] {
  return lexed.read(source, (text) => lexer(text, { gfm: true }));
}

/// GitHub's own rendering, drawn once per text and per link opener (the page keeps one opener for
/// its life, GitHubPage.tsx), so a new opener starts its own cache.
const drawnByOpen = new WeakMap<object, BodyCache<ReactNode[] | null>>();

export function cachedDrawing<O extends object>(
  html: string,
  open: O,
  draw: (html: string, open: O) => ReactNode[] | null,
): ReactNode[] | null {
  let cache = drawnByOpen.get(open);
  if (!cache) {
    cache = new BodyCache();
    drawnByOpen.set(open, cache);
  }
  return cache.read(html, (text) => draw(text, open));
}
