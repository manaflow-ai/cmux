// Rich link previews, served offline: canned metadata for a few real sites plus a
// bare domain card for anything else. Images are procedural PNGs under /media/og_*.

export interface LinkImage {
  id: string; // media id, served at /media/<id>.png
  width: number;
  height: number;
}

export interface LinkPreview {
  url: string;
  title?: string;
  siteName?: string;
  image?: LinkImage;
  icon?: LinkImage;
  state?: "loaded" | "loading" | "tapToLoad";
}

interface Canned {
  match: RegExp;
  build: (m: RegExpMatchArray, url: string) => Omit<LinkPreview, "url">;
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "_").slice(0, 48);
const img = (key: string, width: number, height: number): LinkImage => ({ id: `og_${slug(key)}`, width, height });

const CANNED: Canned[] = [
  {
    // Large landscape card (GitHub's 1200x600 social image).
    match: /^https?:\/\/(?:www\.)?github\.com\/manaflow-ai\/cmux\/pull\/(\d+)/i,
    build: (m) => ({
      title: `Pull Request #${m[1]} · manaflow-ai/cmux`,
      siteName: "GitHub",
      image: img(`gh_pr_${m[1]}`, 1200, 600),
      icon: img("gh_icon", 64, 64),
    }),
  },
  {
    match: /^https?:\/\/(?:www\.)?github\.com\/manaflow-ai\/cmux\/issues\/(\d+)/i,
    build: (m) => ({
      title: `Issue #${m[1]} · manaflow-ai/cmux`,
      siteName: "GitHub",
      image: img(`gh_issue_${m[1]}`, 1200, 600),
      icon: img("gh_icon", 64, 64),
    }),
  },
  {
    match: /^https?:\/\/(?:www\.)?github\.com\/manaflow-ai\/cmux\/?$/i,
    build: () => ({
      title: "GitHub - manaflow-ai/cmux: Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents",
      siteName: "GitHub",
      image: img("gh_repo", 1200, 600),
    }),
  },
  {
    match: /^https?:\/\/(?:www\.)?apple\.com\/iphone\/?/i,
    build: () => ({ title: "iPhone 17 Pro and iPhone Air - Apple", image: img("apple_iphone", 1200, 630), icon: img("apple_icon", 64, 64) }),
  },
  {
    match: /^https?:\/\/(?:www\.)?youtube\.com\/watch\?v=([\w-]+)/i,
    build: (m) => ({ title: "cmux demo: vertical tabs, notifications and agents", siteName: "YouTube", image: img(`yt_${m[1]}`, 1280, 720) }),
  },
  {
    // Square artwork: a narrower card.
    match: /^https?:\/\/open\.spotify\.com\/(?:track|album)\/([\w]+)/i,
    build: (m) => ({ title: "Focus Flow", siteName: "Spotify", image: img(`spotify_${m[1]}`, 640, 640) }),
  },
  {
    // Icon only: a compact card with a trailing thumbnail.
    match: /^https?:\/\/en\.wikipedia\.org\/wiki\/([\w%()-]+)/i,
    build: (m) => ({
      title: `${decodeURIComponent(m[1]).replaceAll("_", " ")} - Wikipedia`,
      icon: img("wikipedia_icon", 160, 160),
    }),
  },
  {
    // Small image: compact card with the image as the thumbnail.
    match: /^https?:\/\/news\.ycombinator\.com\/item\?id=(\d+)/i,
    build: (m) => ({ title: "Show HN: cmux, a terminal for coding agents", siteName: "Hacker News", image: img(`hn_${m[1]}`, 120, 90) }),
  },
];

/** Live bot messages that carry links (start, end, middle, bare). */
export const LINK_MESSAGES = [
  "https://www.apple.com/iphone/",
  "new phones look nice https://www.apple.com/iphone/",
  "https://github.com/manaflow-ai/cmux",
  "demo is up https://www.youtube.com/watch?v=cmuxDemo42",
  "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
  "background reading https://en.wikipedia.org/wiki/Terminal_emulator",
  "https://news.ycombinator.com/item?id=41234567",
  "https://example.com/some/path",
  "see https://en.wikipedia.org/wiki/Ghostty for the history, it's a fun read",
  "call me at (415) 555-0132 if the build breaks",
  "lunch tomorrow at 12:30? the place on 1 Infinite Loop, Cupertino, CA 95014",
];

export function unfurl(url: string): LinkPreview {
  for (const c of CANNED) {
    const m = url.match(c.match);
    if (m) return { url, ...c.build(m, url), state: "loaded" };
  }
  return { url, state: "loaded" };
}

const URL_RE = /\b(?:https?:\/\/|www\.)[^\s<>"]+/gi;

/** The URL Messages turns into a card: one that opens or ends the message. */
export function previewURL(text: string): string | undefined {
  const trimmed = text.trim();
  const matches = [...trimmed.matchAll(URL_RE)];
  if (!matches.length) return undefined;
  const clean = (s: string) => s.replace(/[.,!?;:)]+$/, "");
  const first = matches[0];
  if (first.index === 0) return normalize(clean(first[0]));
  const last = matches[matches.length - 1];
  const raw = clean(last[0]);
  if ((last.index ?? 0) + last[0].length === trimmed.length && raw === last[0]) return normalize(raw);
  return undefined;
}

function normalize(u: string) {
  return /^https?:\/\//i.test(u) ? u : `https://${u}`;
}

/** Every image a preview references, so the media route can serve it. */
export function previewImages(p: LinkPreview): LinkImage[] {
  return [p.image, p.icon].filter((x): x is LinkImage => !!x);
}
