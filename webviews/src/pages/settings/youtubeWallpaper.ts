// YouTube wallpapers: the `youtube:` background id every part agrees on (video-wallpapers contract).
//
//   youtube:<VIDEO_ID>[?start=<S>][&end=<E>][&quality=<Q>]
//
// VIDEO_ID is 11 of [A-Za-z0-9_-]; start and end are whole seconds, 0 <= start < end <= 86400;
// quality is a player height (360 to 2160, 1080 when omitted). Parameters equal to their default are
// dropped, so one video at one range has one id, and no `|` ever appears (the light/dark pair
// `appearance:<a>|<b>` keeps working). Rust validates the id on write; this file only reads a pasted
// link well enough to show its thumbnail and to write that one canonical id.

export const YOUTUBE_PREFIX = "youtube:";
/** The player heights the id accepts, smallest first. */
export const YOUTUBE_QUALITIES = [360, 480, 720, 1080, 1440, 2160] as const;
export const YOUTUBE_DEFAULT_QUALITY = 1080;
/** The longest range a wallpaper loops: one day. */
export const YOUTUBE_MAX_SECONDS = 86_400;

/** A YouTube wallpaper as its parts; `end` null plays to the video's end. */
export type YouTubeWallpaper = {
  video: string;
  start: number;
  end: number | null;
  quality: number;
};

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const HOSTS = new Set([
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  "music.youtube.com",
  "youtube-nocookie.com",
  "www.youtube-nocookie.com",
]);
const PATH_KINDS = new Set(["shorts", "embed", "live", "v", "e"]);

export function isYouTubeId(id: string): boolean {
  return parseYouTubeId(id) !== null;
}

/** The canonical id for `wallpaper`: defaults dropped, parameters in start, end, quality order. */
export function youtubeId(wallpaper: YouTubeWallpaper): string {
  const params: string[] = [];
  if (wallpaper.start > 0) params.push(`start=${wallpaper.start}`);
  if (wallpaper.end !== null) params.push(`end=${wallpaper.end}`);
  if (wallpaper.quality !== YOUTUBE_DEFAULT_QUALITY) params.push(`quality=${wallpaper.quality}`);
  return `${YOUTUBE_PREFIX}${wallpaper.video}${params.length ? `?${params.join("&")}` : ""}`;
}

/** A `youtube:` id's parts, or null when it breaks the contract. Accepts the parameters in any order
 * and with defaults spelled out, as a hand-edited settings file might hold them. */
export function parseYouTubeId(id: string): YouTubeWallpaper | null {
  if (!id.startsWith(YOUTUBE_PREFIX)) return null;
  const [video, query, ...rest] = id.slice(YOUTUBE_PREFIX.length).split("?");
  if (rest.length > 0 || video === undefined || !VIDEO_ID.test(video)) return null;
  const wallpaper: YouTubeWallpaper = { video, start: 0, end: null, quality: YOUTUBE_DEFAULT_QUALITY };
  if (query === undefined) return wallpaper;
  const seen = new Set<string>();
  for (const pair of query.split("&")) {
    const [key, value, ...extra] = pair.split("=");
    if (extra.length > 0 || key === undefined || value === undefined || seen.has(key) || !/^\d+$/.test(value))
      return null;
    seen.add(key);
    const number = Number(value);
    if (key === "start") wallpaper.start = number;
    else if (key === "end") wallpaper.end = number;
    else if (key === "quality") wallpaper.quality = number;
    else return null;
  }
  return validRange(wallpaper.start, wallpaper.end) &&
    (YOUTUBE_QUALITIES as readonly number[]).includes(wallpaper.quality)
    ? wallpaper
    : null;
}

/** Whether `start`..`end` is a range the id may hold. */
export function validRange(start: number, end: number | null): boolean {
  if (!Number.isInteger(start) || start < 0 || start >= YOUTUBE_MAX_SECONDS) return false;
  if (end === null) return true;
  return Number.isInteger(end) && end > start && end <= YOUTUBE_MAX_SECONDS;
}

/** A pasted link's video and its `t`/`start` time (seconds, 0 without one); null when it names no
 * video. Takes watch?v=, youtu.be/, shorts/, embed/, live/, m., music., youtube-nocookie.com, a
 * `youtube:` id, or a bare 11-character id. */
export function parseYouTubeLink(text: string): { video: string; start: number } | null {
  const trimmed = text.trim();
  if (VIDEO_ID.test(trimmed)) return { video: trimmed, start: 0 };
  const id = parseYouTubeId(trimmed);
  if (id) return { video: id.video, start: id.start };
  let url: URL;
  try {
    url = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  const host = url.hostname.toLowerCase();
  const segments = url.pathname.split("/").filter(Boolean);
  let video: string | undefined;
  if (host === "youtu.be" || host === "www.youtu.be") video = segments[0];
  else if (HOSTS.has(host)) {
    if (segments[0] === "watch") video = url.searchParams.get("v") ?? undefined;
    else if (segments[0] !== undefined && PATH_KINDS.has(segments[0])) video = segments[1];
  }
  if (video === undefined || !VIDEO_ID.test(video)) return null;
  // `t` in the query or the fragment (`#t=1m30s`), else `start`.
  const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
  const time = url.searchParams.get("t") ?? fragment.get("t") ?? url.searchParams.get("start");
  return { video, start: (time === null ? 0 : linkSeconds(time)) ?? 0 };
}

/** A link's time: `90`, `90s`, `1m30s`, `1h2m3s`; null when unreadable. */
export function linkSeconds(text: string): number | null {
  const match = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$/.exec(text.trim());
  if (!match || text.trim() === "") return null;
  const [, hours = "0", minutes = "0", seconds = "0"] = match;
  return Number(hours) * 3600 + Number(minutes) * 60 + Number(seconds);
}

/** A typed time, `m:ss`, `h:mm:ss` or plain seconds; undefined when empty, null when unreadable. */
export function parseClock(text: string): number | null | undefined {
  const trimmed = text.trim();
  if (trimmed === "") return undefined;
  if (!/^\d+(?::\d{1,2}){0,2}$/.test(trimmed)) return null;
  const parts = trimmed.split(":").map(Number);
  if (parts.slice(1).some((part) => part >= 60)) return null;
  return parts.reduce((total, part) => total * 60 + part, 0);
}

/** Seconds as `m:ss`, or `h:mm:ss` from an hour. */
export function formatClock(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = String(seconds % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}
