// The video viewer's playback rules, apart from React (VideoPlayback.tsx): its speeds, a frame step,
// the keys and how a before/after pair keeps the second clip on the first one's frame. Leo, 2026-11-22:
// "is there a way we can just watch the .mp4s in the app? i want that. in-app video player."

/// The speeds the viewer offers, slowest first.
export const PLAYBACK_RATES = [0.5, 1, 2] as const;
export type PlaybackRate = (typeof PLAYBACK_RATES)[number];

/// One frame when the clip does not say its rate: screen recordings are 30 or 60 fps, and a 30 fps
/// step lands on every frame of a 30 fps clip and every other frame of a 60 fps one.
export const DEFAULT_FRAME_SECONDS = 1 / 30;

/// How far a pair's second clip may drift from the first before it is put back on its frame.
export const PAIR_DRIFT_SECONDS = 0.05;

/// The rate one step slower (`-1`) or faster (`1`) than `rate`, held at the ends.
export function nextRate(rate: number, direction: -1 | 1): PlaybackRate {
  const at = PLAYBACK_RATES.findIndex((known) => known >= rate - 1e-6);
  const index = at < 0 ? PLAYBACK_RATES.length - 1 : at;
  const next = Math.min(PLAYBACK_RATES.length - 1, Math.max(0, index + direction));
  return PLAYBACK_RATES[next]!;
}

/// Where a frame step from `time` lands, inside `[0, duration]`.
export function steppedTime(time: number, direction: -1 | 1, duration: number, frame = DEFAULT_FRAME_SECONDS): number {
  const step = Number.isFinite(frame) && frame > 0 ? frame : DEFAULT_FRAME_SECONDS;
  const end = Number.isFinite(duration) && duration > 0 ? duration : Infinity;
  return Math.min(end, Math.max(0, time + direction * step));
}

/// The time the pair's second clip should seek to so it shows the first one's frame, or undefined
/// when it is close enough (or past its own end, where it holds its last frame).
export function followerSeek(leadTime: number, followerTime: number, followerDuration: number): number | undefined {
  if (!Number.isFinite(leadTime)) return undefined;
  const target =
    Number.isFinite(followerDuration) && followerDuration > 0 ? Math.min(leadTime, followerDuration) : leadTime;
  return Math.abs(target - followerTime) > PAIR_DRIFT_SECONDS ? target : undefined;
}

/// `m:ss.t` for the viewer's clock: tenths, so a frame step shows it moved.
export function clockTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00.0";
  const tenths = Math.floor(seconds * 10);
  const m = Math.floor(tenths / 600);
  const s = Math.floor((tenths % 600) / 10);
  return `${m}:${String(s).padStart(2, "0")}.${tenths % 10}`;
}

/// What a key does in the viewer; undefined for a key it leaves alone.
export type PlaybackKey =
  | { kind: "toggle" }
  | { kind: "step"; direction: -1 | 1 }
  | { kind: "rate"; direction: -1 | 1 }
  | { kind: "loop" };

export function playbackKey(event: {
  key: string;
  metaKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
}): PlaybackKey | undefined {
  if (event.metaKey || event.ctrlKey || event.altKey) return undefined;
  switch (event.key) {
    case " ":
    case "k":
    case "K":
      return { kind: "toggle" };
    case ",":
      return { kind: "step", direction: -1 };
    case ".":
      return { kind: "step", direction: 1 };
    case "[":
      return { kind: "rate", direction: -1 };
    case "]":
      return { kind: "rate", direction: 1 };
    case "l":
    case "L":
      return { kind: "loop" };
    default:
      return undefined;
  }
}

/// A pair's two captions: the labels the reply wrote, else Before and After when the names say so in
/// that order, else the file names.
export function pairCaptions(
  items: Array<{ src: string; alt: string; label?: string }>,
  names: { before: string; after: string },
): [string, string] {
  const name = (item: { src: string; alt: string; label?: string }) =>
    item.label || item.alt || item.src.split(/[?#]/)[0]!.split("/").filter(Boolean).at(-1) || item.src;
  const [a, b] = [items[0]!, items[1]!];
  if (a.label || b.label || a.alt || b.alt) return [name(a), name(b)];
  const beforeFirst = /before/i.test(a.src) && /after/i.test(b.src);
  return beforeFirst ? [names.before, names.after] : [name(a), name(b)];
}
