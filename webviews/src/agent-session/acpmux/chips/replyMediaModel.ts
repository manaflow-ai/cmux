import { callChipHost } from "./host";
import { isDeniedPath, linkPath } from "./paths";
import { mediaKind } from "./mediaKind";

export { mediaKind } from "./mediaKind";

const ATTACHMENT = /^\/user-attachments\/assets\/[\w-]+$/;

export function webURL(src: string): URL | undefined {
  try {
    const url = new URL(src);
    return url.protocol === "https:" && !url.username && !url.password ? url : undefined;
  } catch {
    return undefined;
  }
}

/// Whether `src` is web media: an https link to a video or audio file, or a GitHub user attachment.
export function isRemoteMedia(src: string): boolean {
  const url = webURL(src);
  if (!url) return false;
  return (url.hostname === "github.com" && ATTACHMENT.test(url.pathname)) || mediaKind(url.pathname) !== undefined;
}

/// The host request that opens `source` in a tab, as a link to it would open: a web video
/// (https only) in a cmux browser tab (`browser.openIn` with `cmux`), a file through the path
/// chip's `link.openPath` (cmux's file pages, which play video and run nothing). The host checks
/// either again and places the tab by the link setting. Nil for anything else.
export function mediaOpenRequest(source: string): { method: string; params: Record<string, string> } | undefined {
  if (webURL(source)) return { method: "browser.openIn", params: { url: source, browserId: "cmux" } };
  // A path or a local `file://` URL; any other scheme (and a file URL on another host) opens nothing.
  const path = linkPath(source);
  if (!path || isDeniedPath(path)) return undefined;
  return { method: "link.openPath", params: { path } };
}

/// A video's length as the thumbnail shows it: `m:ss`, or `h:mm:ss` from an hour. Nil when the
/// length is unknown (a live stream, metadata not read yet).
export function formatDuration(seconds: number): string | undefined {
  if (!Number.isFinite(seconds) || seconds <= 0) return undefined;
  const total = Math.max(1, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

/// The URL the pane plays `source` (a path, a `file://` URL or a web link) by, as the host grants it
/// (`media.load`): a `__media/` URL on the page's own origin that the host serves in byte
/// ranges, so a file of any size streams and is never read whole. Nil when the host refuses it.
/// A local path is asked on every mount, never cached across them: it names a different file in
/// another chat (a remote one names its own machine's), and only the host knows which chat the pane
/// shows now. The host hands the same file the same URL, so asking again costs one round trip. A web
/// link names the same media in every chat, so its copy is kept (`webGranted`).
export async function loadPlayableMedia(source: string): Promise<string | undefined> {
  const web = webURL(source) !== undefined;
  const known = web ? webGranted.get(source) : undefined;
  if (known) return known;
  const reply = await callChipHost("media.load", { src: source });
  const url = (reply as { src?: unknown } | undefined)?.src;
  // The gallery's fixture answers a data URL; the page's CSP plays only its own media URLs, on the
  // pane's own host or the shared page host (`cmux-page://cmux.agent/__media/`).
  if (typeof url !== "string" || !GRANTED_MEDIA.test(url)) return undefined;
  if (web) webGranted.set(source, url);
  return url;
}

/// A URL the host grants: a `__media/` path on one of the agent page's two origins, or the gallery's data URL.
const GRANTED_MEDIA = /^(cmux-agent:\/\/pane\/__media\/|cmux-page:\/\/cmux\.agent\/__media\/|data:(video|audio)\/)/;

/// The host's copy of each web link already fetched, so a remount plays it without Load again.
export const webGranted = new Map<string, string>();

/// How long a player may wait for data with nothing to show before it counts as failed: the native
/// player's spinner never turns forever over a file that never streams (a granted URL whose ranges
/// never come, a codec it reads the header of and then stalls on; Leo, 2026-11-22: two tiles that
/// only spun under "WHAT THE FUCK IS THIS SITUATION MAN WITH THESE ATTACHMENTS!?").
export const PLAYBACK_STALL_MS = 15_000;

/// Watches `video`, asked to play, for a wait that never ends: from now, and from every `waiting` or
/// `stalled` after, it must reach data it can play (`canplay`, `playing`) within `ms`, or `onStall`
/// runs once. A pause (the person's) or the player leaving stops the clock; a play starts it again.
/// O(1) per media event; one timer at most. Returns the stop.
export function watchPlaybackStall(video: HTMLMediaElement, onStall: () => void, ms = PLAYBACK_STALL_MS): () => void {
  const view = video.ownerDocument.defaultView;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let stalled = false;
  const clear = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  };
  const arm = () => {
    clear();
    if (stalled || video.paused) return;
    // timeout: one bounded wait for data; cleared by data, a pause or the player leaving.
    timer = (view ?? globalThis).setTimeout(() => {
      timer = undefined;
      if (stalled || video.paused || video.readyState >= 3) return;
      stalled = true;
      onStall();
    }, ms);
  };
  const waits = ["waiting", "stalled", "play"] as const;
  const goes = ["canplay", "canplaythrough", "playing", "pause", "ended"] as const;
  for (const name of waits) video.addEventListener(name, arm);
  for (const name of goes) video.addEventListener(name, clear);
  if (!video.paused && video.readyState < 3) arm();
  return () => {
    clear();
    for (const name of waits) video.removeEventListener(name, arm);
    for (const name of goes) video.removeEventListener(name, clear);
  };
}
