// The local web page a turn started or mentioned: a dev server's "Local: http://localhost:5173/",
// a prompt asking about http://127.0.0.1:3000/admin, an answer pointing at it. The turn's preview
// card shows the latest one. Only loopback hosts the pane's frame may load qualify (the page's CSP
// `frame-src` and URL+AgentPanePreview.swift name the same ones); 0.0.0.0, which a server binds but a
// browser does not reach, reads as localhost.
//
// The text is not trusted: a shell call's output can carry a fetched page's words. So the card's
// frame loads nothing until the reader clicks "Load preview". That click is the reader's consent to
// the address the card shows, so the frame then loads that address (`previewFrameUrl`): the same
// loopback host and port, its path and query, no fragment. The frame stays sandboxed without
// forms and takes no input, except a component gallery stage (`isGalleryFrame`): one live
// component, drawn at its own size and usable in place.
import type { AcpmuxRow } from "../model";
import { stripAnsi } from "./toolOutput";

/// Height of the card's thumbnail after the reader clicks Load preview (`.acpmux-turn-preview-frame`
/// in styles.css); the page draws at four times its size, scaled down.
export const PREVIEW_FRAME_HEIGHT = 180;
/// Height of a gallery stage's live frame after Load preview (`.acpmux-turn-preview-frame--live` in
/// styles.css).
export const GALLERY_FRAME_HEIGHT = 360;
/// Height of an unloaded card: one compact row, no thumbnail box
/// (`.acpmux-turn-preview[data-compact] .acpmux-turn-preview-head` in conversation.css).
export const PREVIEW_COMPACT_HEIGHT = 36;
/// Height of a loaded card's head over its frame (`.acpmux-turn-preview-head` in styles.css).
export const PREVIEW_HEAD_HEIGHT = 58;

// The host ends the name (`localhost.evil.com` is not loopback, a sentence's closing dot is fine);
// a colon after it must start a port.
const LOCAL_URL =
  /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?![\w-]|\.[\w-])(?::\d{1,5}(?!\d)|(?!:))(?:[/?#][^\s"'`<>()[\]{}]*)?/gi;

// An address given as a setting's value is a service the agent talks to, not a page to look at:
// `ANTHROPIC_BASE_URL=http://127.0.0.1:31415` (a model gateway, Leo 2026-10-19), `"baseUrl":
// "http://localhost:8080"`, `--api-url http://...`, `proxy: http://...`.
const SETTING_BEFORE = [
  // An environment variable: `ANTHROPIC_BASE_URL=`, `PORT_URL="` (upper case only).
  /\b[A-Z][A-Z0-9_]*=["']?$/,
  // A quoted key: `"baseUrl": "`, `'api_endpoint': `.
  /["'][\w-]*(?:url|uri|endpoint|proxy|base)["']\s*[:=]\s*["']?$/i,
  // An identifier ending in one: `baseUrl = `, `api_url: `, `upstreamProxy=`.
  /\b[a-z][\w]*?(?:Url|URL|Uri|URI|Endpoint|Proxy|_url|_uri|_endpoint|_proxy)\s*[:=]\s*["']?$/,
  // A YAML or INI key on its own line: `proxy: `, `url = `.
  /(?:^|\n)\s*(?:url|uri|base|endpoint|proxy)\s*[:=]\s*["']?$/,
  // A command-line flag: `--api-url `, `--proxy=`, `--endpoint "`.
  /(?:^|\s)--(?:[\w-]*-)?(?:url|uri|endpoint|proxy|api|base)(?:-[\w-]+)?[=\s]["']?$/,
];
// An API route answers a program, not a reader: `/v1/messages`, `/api/...`, `/graphql`, `/rpc`.
const API_PATH = /^\/(?:v\d+(?:\/|$)|api(?:\/|$)|graphql(?:\/|$)|rpc(?:\/|$)|healthz?(?:\/|$))/i;

/// The latest loopback page in `texts`, normalized (trailing punctuation dropped, 0.0.0.0 as
/// localhost), or nil. Settings' values and API routes are not pages (SETTING_BEFORE, API_PATH).
export function latestLocalUrl(texts: readonly (string | undefined)[]): string | undefined {
  let found: string | undefined;
  for (const text of texts) {
    if (!text) continue;
    // Dev servers colour the address itself (`localhost:\x1b[1m5173`).
    const plain = stripAnsi(text);
    for (const match of plain.matchAll(LOCAL_URL)) {
      const before = plain.slice(Math.max(0, match.index - 64), match.index);
      if (SETTING_BEFORE.some((setting) => setting.test(before))) continue;
      const url = parse(match[0].replace(/[.,;:!?*_]+$/, ""));
      if (url && !API_PATH.test(new URL(url).pathname)) found = url;
    }
  }
  return found;
}

function parse(text: string): string | undefined {
  try {
    const url = new URL(text);
    if (url.hostname === "0.0.0.0") url.hostname = "localhost";
    const port = url.port ? Number(url.port) : undefined;
    if (port !== undefined && (port < 1 || port > 65_535)) return undefined;
    return url.href;
  } catch {
    return undefined;
  }
}

/// The page a turn started or mentioned: its prompt, its answers, and its shell calls' commands
/// and output (where a dev server prints its address). Other tools' input and output (a file
/// read, a web fetch) are left out.
export function turnPreviewUrl(user: AcpmuxRow, turn: readonly AcpmuxRow[]): string | undefined {
  return latestLocalUrl([
    user.text,
    ...turn.flatMap((row) => [
      row.kind === "assistant" ? row.text : undefined,
      ...(row.items ?? []).flatMap((item) =>
        item.tool?.kind === "execute" ? [item.tool.command, item.tool.output] : [],
      ),
    ]),
  ]);
}

/// The Debug toggle `agentPane.debug.turnPreviewCards` (off by default; the app sets
/// `data-turn-preview-cards="on"` on `<html>`): a turn that started or mentioned a local page gets
/// its preview card. Off, the address is only the reply's link (Leo 2026-10-20: a mentioned dev
/// server is not worth a card nobody asked for).
export function turnPreviewCardsOn(): boolean {
  return typeof document !== "undefined" && document.documentElement.dataset.turnPreviewCards === "on";
}

/// What the card's frame loads after the click: the address the card shows (host, port, path and
/// query as found; the fragment is the page's own and is not shown).
export function previewFrameUrl(url: string): string {
  const parsed = new URL(url);
  return `${parsed.origin}${parsed.pathname}${parsed.search}`;
}

/// The gallery's mounts (src/gallery/ENTRIES.md, "Seeing it"): `bun run dev` and `gallery:dev`
/// serve `/gallery/`, the live gallery `/live/`, a branch's `/wt/<name>/`, the static build `/latest/`.
const GALLERY_STAGE_PATH = /^\/(?:gallery|live|latest|wt\/[\w.-]+)\/frame\.html$/;

/// A component gallery stage on loopback: `<mount>frame.html?entry=<id>` under one of the
/// gallery's own mounts (src/gallery/env.ts names the query), one state of one component. Its card
/// draws it at full size and lets the reader use it in place, instead of a scaled thumbnail that
/// opens a tab. The address comes from untrusted text, so any other path stays a thumbnail.
export function isGalleryFrame(url: string): boolean {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (!["localhost", "127.0.0.1", "0.0.0.0"].includes(parsed.hostname)) return false;
    return GALLERY_STAGE_PATH.test(parsed.pathname) && Boolean(parsed.searchParams.get("entry"));
  } catch {
    return false;
  }
}

/// The height of a loaded preview card's frame for `url`.
export function previewFrameHeight(url: string): number {
  return isGalleryFrame(url) ? GALLERY_FRAME_HEIGHT : PREVIEW_FRAME_HEIGHT;
}

/// A preview card's row height with the 6px card margin and 8px below it: the compact row until the
/// reader clicks Load preview, then the head over the frame.
export function previewCardHeight(url: string | undefined, loaded: boolean): number {
  if (!loaded || !url) return PREVIEW_COMPACT_HEIGHT + 6 + 8;
  return PREVIEW_HEAD_HEIGHT + previewFrameHeight(url) + 6 + 8;
}
