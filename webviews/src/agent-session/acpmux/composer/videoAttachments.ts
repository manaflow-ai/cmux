// An attached video's poster, length and key frames (Leo, 2026-10-25: "also why dont we have
// previews of videos we should"). The page cannot decode a video (its CSP plays no local file, and
// reading a recording's bytes froze the composer), so the host reads it with AVFoundation, off its
// main thread (`video.info`, AgentPaneVideoInfo.swift): only for a file whose path it knows, in a
// chat on this Mac. The answer goes on the chip (`ComposerAttachment.video`): its tile draws the
// poster and length, and the prompt sends the frames, so a send never waits on a read it could do
// without. A send made while a read is out waits for it a few seconds at most (VIDEO_INFO_DEADLINE_MS);
// a chip whose read failed or timed out stays a file chip and goes as its path alone.
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

/// The chips whose video is being read, by id, so a chip draws its busy tile wherever it shows.
let reading: ReadonlySet<string> = new Set();
const listeners = new Set<() => void>();
function setReading(id: string, on: boolean) {
  if (reading.has(id) === on) return;
  const next = new Set(reading);
  if (on) next.add(id);
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

/// Reads the video of each staged video chip that has none yet (`enabled`: a chat on this Mac, whose
/// files the host may read) and puts it on the chip. Answers how many staged chips are still being
/// read, for the send's wait (useSendWhenAttached): a removed chip, a refusal or the deadline ends it.
export function useVideoInfo(
  attachments: readonly ComposerAttachment[],
  setAttachments: (update: (current: ComposerAttachment[]) => ComposerAttachment[]) => void,
  enabled: () => boolean,
): number {
  /// Each staged chip is asked once; one removed and added again is asked again.
  const asked = useRef(new Set<string>());
  const mounted = useRef(true);
  const shown = useSyncExternalStore(subscribe, readingNow, readingNow);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useEffect(() => {
    for (const id of asked.current) if (!attachments.some((chip) => chip.id === id)) asked.current.delete(id);
    for (const chip of attachments) {
      if (!isVideoAttachment(chip) || chip.video || asked.current.has(chip.id) || !enabled()) continue;
      asked.current.add(chip.id);
      const { id, path } = chip;
      setReading(id, true);
      // The send waits no longer than this; a late answer still draws the poster.
      const deadline = setTimeout(() => setReading(id, false), VIDEO_INFO_DEADLINE_MS);
      void callChipHost("video.info", { src: path }).then((answer) => {
        clearTimeout(deadline);
        setReading(id, false);
        const video = parseVideoInfo(answer);
        if (!video || !mounted.current) return;
        setAttachments((current) =>
          current.some((staged) => staged.id === id && staged.path === path && !staged.video)
            ? current.map((staged) => (staged.id === id && staged.path === path ? { ...staged, video } : staged))
            : current,
        );
      });
    }
    // `enabled` is read when a chip comes in, as the intake's options are.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [attachments, setAttachments]);
  return attachments.filter((chip) => shown.has(chip.id)).length;
}
