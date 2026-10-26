// An attached video's poster, length and key frames (Leo, 2026-10-25: "also why dont we have
// previews of videos we should"). The page cannot decode a video (its CSP plays no local file, and
// reading a recording's bytes froze the composer), so the host reads it with AVFoundation, off its
// main thread (`video.info`, AgentPaneVideoInfo.swift): only for a file whose path it knows, in a
// chat on this Mac. The answer goes on the chip (`ComposerAttachment.video`): its tile draws the
// poster and length, and its key frames are there for the prompt (sent with the video's link by
// videoPrompt.ts, which comes with the sent bubble's tile). A send made while a read is out waits
// for it a few seconds at most (VIDEO_INFO_DEADLINE_MS); a chip whose read failed or timed out
// stays a file chip and goes as its path alone.
import { useEffect, useRef, useSyncExternalStore } from "react";
import type { ComposerAttachment } from "../attachments";
import { callChipHost } from "../chips/host";

/// What the host answers for a video (AgentPaneVideoInfo.Info). `poster` is a JPEG `data:` URL of at
/// most 320 px; `frames` are base64 JPEGs of at most 1024 px, spread over the video, each with its time.
export type VideoInfo = {
  durationMs: number;
  width: number;
  height: number;
  poster: string;
  frames: { atMs: number; data: string }[];
};

/// The movies the host reads (AgentPaneReplyPaths.videoExtensions).
const VIDEO_PATH = /\.(mov|mp4|m4v)$/i;
/// The most frames a chip keeps, whatever the host says.
const MAX_FRAMES = 8;
/// How long a send waits for a video's read before it goes without the frames.
export const VIDEO_INFO_DEADLINE_MS = 5_000;

/// Whether `attachment` is a video that goes as its path: a link chip (a dropped, pasted or chosen
/// file, or a saved copy) whose name is a movie's. The + menu's chooser gives no type, so the name decides.
export function isVideoAttachment(attachment: ComposerAttachment): attachment is ComposerAttachment & { path: string } {
  return attachment.kind === "link" && typeof attachment.path === "string" && VIDEO_PATH.test(attachment.path);
}

const positive = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value > 0;

/// The host's `video.info` answer, checked; undefined for anything else (a refusal, an older host).
export function parseVideoInfo(value: unknown): VideoInfo | undefined {
  const raw = value as Partial<Record<keyof VideoInfo, unknown>> | null | undefined;
  if (!raw || !positive(raw.durationMs) || !positive(raw.width) || !positive(raw.height)) return undefined;
  if (typeof raw.poster !== "string" || !raw.poster.startsWith("data:image/jpeg;base64,")) return undefined;
  const frames = (Array.isArray(raw.frames) ? raw.frames : []).flatMap((frame: unknown) => {
    const { atMs, data } = (frame ?? {}) as { atMs?: unknown; data?: unknown };
    return typeof atMs === "number" && Number.isFinite(atMs) && atMs >= 0 && typeof data === "string" && data
      ? [{ atMs, data }]
      : [];
  });
  return {
    durationMs: raw.durationMs,
    width: Math.round(raw.width),
    height: Math.round(raw.height),
    poster: raw.poster,
    frames: frames.slice(0, MAX_FRAMES),
  };
}

/// The reads out now, by chip id (each read its own token), so a chip draws its busy tile wherever it
/// shows; a read that ends clears only its own token, never a later read of the same chip.
let reading: ReadonlyMap<string, symbol> = new Map();
const listeners = new Set<() => void>();
function setReading(id: string, token: symbol, on: boolean) {
  if (on ? reading.get(id) === token : reading.get(id) !== token) return;
  const next = new Map(reading);
  if (on) next.set(id, token);
  else next.delete(id);
  reading = next;
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const readingNow = () => reading;

/// Whether chip `id`'s video is being read.
export function useVideoReading(id: string): boolean {
  return useSyncExternalStore(subscribe, readingNow, readingNow).has(id);
}

/// Reads the video of each staged video chip that has none yet, while `enabled` (a chat on this Mac,
/// whose files the host may read), and puts it on the chip. Answers how many staged chips are still
/// being read, for the send's wait (useSendWhenAttached): a removed chip, a refusal, the deadline or
/// the composer going away ends it.
export function useVideoInfo(
  attachments: readonly ComposerAttachment[],
  setAttachments: (update: (current: ComposerAttachment[]) => ComposerAttachment[]) => void,
  enabled: boolean,
): number {
  /// The chips asked (each chip object once: one added again, or replaced without its video, is a
  /// new object and is asked again), and the reads this composer has out, to end on unmount.
  const asked = useRef(new WeakSet<ComposerAttachment>());
  const out = useRef(new Map<symbol, { id: string; deadline: ReturnType<typeof setTimeout> }>());
  const mounted = useRef(true);
  const shown = useSyncExternalStore(subscribe, readingNow, readingNow);
  useEffect(() => {
    mounted.current = true;
    const reads = out.current;
    return () => {
      mounted.current = false;
      for (const [token, { id, deadline }] of reads) {
        clearTimeout(deadline);
        setReading(id, token, false);
      }
      reads.clear();
    };
  }, []);
  useEffect(() => {
    if (!enabled) return;
    for (const chip of attachments) {
      if (!isVideoAttachment(chip) || chip.video || asked.current.has(chip)) continue;
      asked.current.add(chip);
      const { id, path } = chip;
      const token = Symbol(id);
      const end = () => {
        const read = out.current.get(token);
        if (read) clearTimeout(read.deadline);
        out.current.delete(token);
        setReading(id, token, false);
      };
      setReading(id, token, true);
      // The send waits no longer than this; a late answer still draws the poster.
      out.current.set(token, { id, deadline: setTimeout(end, VIDEO_INFO_DEADLINE_MS) });
      void callChipHost("video.info", { src: path }).then((answer) => {
        end();
        const video = parseVideoInfo(answer);
        // An answer after its deadline still draws the poster, unless the composer went away.
        if (!video || !mounted.current) return;
        setAttachments((current) =>
          current.some((staged) => staged.id === id && staged.path === path && !staged.video)
            ? current.map((staged) => (staged.id === id && staged.path === path ? { ...staged, video } : staged))
            : current,
        );
      });
    }
  }, [attachments, setAttachments, enabled]);
  return attachments.filter((chip) => shown.has(chip.id)).length;
}
