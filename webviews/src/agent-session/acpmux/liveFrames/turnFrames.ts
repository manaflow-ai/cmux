// A turn's frames: pictures acpmux keeps of the chat's page while the turn ran (the sibling lane's
// `_acpmux/turn_frames`, capability `turn-frames-v1`). The strip under a turn's edited-files card
// (TurnFramesStrip.tsx) and the dockable preview (FramesDock.tsx) both read them. This file is the
// only place that knows the wire shape: the daemon's exact reply is fixed here, in `readFrame`
// and the two request builders, and nothing else changes.
//
// Wire shape coded against (adjust here when the daemon's lands):
//   `_acpmux/turn_frames {sessionId, turnId}`   -> {frames: [Frame]}
//   `_acpmux/turn_frames {sessionId, sinceSeq}` -> {frames: [Frame], seq}   (the newest since)
//   Frame = {index, trigger, at, thumb, full, width, height, distance}; `thumb` and `full` are data
//   URLs or `{mimeType, data}`. A `full` that is a handle, not a picture, falls back to the thumb.
// The CSP is `img-src data:`, so only data URLs ever reach an <img>.

export const TURN_FRAMES_CAPABILITY = "turn-frames-v1";
export const TURN_FRAMES_METHOD = "_acpmux/turn_frames";

export type TurnFrame = {
  index: number;
  /// What took the frame (`turn-start`, `edit`, `navigation`, `turn-end`, ...): shown as a caption.
  trigger: string;
  /// Epoch milliseconds.
  at: number;
  /// Data URL of the small picture.
  thumb: string;
  /// Data URL of the whole picture (the thumb when the daemon sent only a handle).
  full: string;
  width: number;
  height: number;
  /// How far this frame is from the one before it (0 for the first), `0..1`.
  distance: number;
};

const num = (value: unknown, fallback = 0): number =>
  typeof value === "number" && Number.isFinite(value) ? value : fallback;

/// A data URL from a string that is one, or from `{mimeType, data}` (as `_acpmux/turn_shots` sends).
export function pictureOf(value: unknown): string | undefined {
  if (typeof value === "string") return /^data:image\/[a-z0-9.+-]+;base64,/i.test(value) ? value : undefined;
  if (!value || typeof value !== "object") return undefined;
  const { mimeType, data } = value as { mimeType?: unknown; data?: unknown };
  if (typeof data !== "string" || !data) return undefined;
  const type = typeof mimeType === "string" && /^image\/[a-z0-9.+-]+$/.test(mimeType) ? mimeType : "image/png";
  return `data:${type};base64,${data}`;
}

/// One frame from the wire; undefined when it has no picture to draw.
export function readFrame(value: unknown, position = 0): TurnFrame | undefined {
  if (!value || typeof value !== "object") return undefined;
  const frame = value as Record<string, unknown>;
  const thumb = pictureOf(frame.thumb) ?? pictureOf(frame.full);
  if (!thumb) return undefined;
  return {
    index: num(frame.index, position),
    trigger: typeof frame.trigger === "string" ? frame.trigger : "",
    at: num(frame.at),
    thumb,
    full: pictureOf(frame.full) ?? thumb,
    width: num(frame.width),
    height: num(frame.height),
    distance: num(frame.distance),
  };
}

/// A reply's frames, in order and without duplicate indexes (the last of an index wins).
export function readFrames(reply: unknown): TurnFrame[] {
  const list = reply && typeof reply === "object" ? (reply as { frames?: unknown }).frames : undefined;
  if (!Array.isArray(list)) return [];
  const byIndex = new Map<number, TurnFrame>();
  list.forEach((item, position) => {
    const frame = readFrame(item, position);
    if (frame) byIndex.set(frame.index, frame);
  });
  return [...byIndex.values()].sort((a, b) => a.index - b.index);
}

/// The screen a native-window preview streams through cmux-rd (the daemon's `screen`, decided in
/// `turn_frames.rs` `screen_offer`): the hub device a viewer opens, and its name.
export type LiveScreen = { device: string; name: string };

/// A latest-since-seq reply: the newest frame, the seq to ask from next, and what the window shows
/// (`surface`: `page`, `simulator` or `window`) with the screen to stream when the daemon offers one.
export type Latest = { frame?: TurnFrame; seq: number; surface?: string; screen?: LiveScreen };

const DEVICE = /^[A-Za-z0-9-]{1,128}$/;

function readScreen(value: unknown): LiveScreen | undefined {
  if (!value || typeof value !== "object") return undefined;
  const { device, name } = value as { device?: unknown; name?: unknown };
  if (typeof device !== "string" || !DEVICE.test(device)) return undefined;
  return { device, name: typeof name === "string" ? name : "" };
}

/// The newest frame of a latest-since-seq reply and the seq to ask from next (the reply's own,
/// else the one asked from).
export function readLatest(reply: unknown, asked: number): Latest {
  const frames = readFrames(reply);
  const body = reply && typeof reply === "object" ? (reply as { seq?: unknown; surface?: unknown; screen?: unknown }) : {};
  const seq = num(body.seq, asked);
  const surface = typeof body.surface === "string" ? body.surface : undefined;
  return { frame: frames[frames.length - 1], seq, surface, screen: readScreen(body.screen) };
}

/// `<scheme>://mac-screen?device=...&name=...`: the app's Mac Screen tab, cmux-rd's viewer, on
/// `screen`. The scheme is the host's (links.ts), so a tagged build opens itself.
export function screenLink(scheme: string, screen: LiveScreen): string {
  const query = new URLSearchParams({ device: screen.device.toLowerCase() });
  if (screen.name) query.set("name", screen.name);
  return `${scheme}://mac-screen?${query.toString()}`;
}

export const turnFramesParams = (sessionId: string, turnId: string) => ({ sessionId, turnId });
/// One frame with its whole picture: the list leaves `full` out to keep the reply small.
export const frameFullParams = (sessionId: string, turnId: string, index: number) => ({ sessionId, turnId, index });
export const latestFrameParams = (sessionId: string, sinceSeq: number) => ({ sessionId, sinceSeq });

/// What the pane provides: the frames of the turn that holds a row, and the live read.
export type TurnFramesReader = {
  /// Changes when a turn ends, so cards re-read.
  version?: string;
  peek(rowId: string): { frames: TurnFrame[] } | undefined;
  read(rowId: string): Promise<TurnFrame[]>;
  /// Frame `index`'s whole picture (a data URL), fetched when the image viewer opens it; undefined
  /// when the daemon has none, and the viewer keeps the thumb.
  full?(rowId: string, index: number): Promise<string | undefined>;
};
