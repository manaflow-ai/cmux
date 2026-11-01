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
import { parseVideoTranscript } from "./videoTranscript";

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
/// shows; a read that ends clears only its own token, never a later read of the same chip. `info` is
/// the video's own read (`video.info`, the tile spins); `transcript` its speech's (`video.transcript`,
/// videoTranscript.ts), which the send waits for too but which draws nothing.
type Kind = "info" | "transcript";
let busy: Readonly<Record<Kind, ReadonlyMap<string, symbol>>> = { info: new Map(), transcript: new Map() };
const listeners = new Set<() => void>();
function setBusy(kind: Kind, id: string, token: symbol, on: boolean) {
  const reading = busy[kind];
  if (on ? reading.get(id) === token : reading.get(id) !== token) return;
  const next = new Map(reading);
  if (on) next.set(id, token);
  else next.delete(id);
  busy = { ...busy, [kind]: next };
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const busyNow = () => busy;

/// Whether chip `id`'s video is being read.
export function useVideoReading(id: string): boolean {
  return useSyncExternalStore(subscribe, busyNow, busyNow).info.has(id);
}

/// A read out now: the chip object it was asked for (its answer goes on that chip only; a transcript's
/// on the chip that holds `video`, the answer it follows), and while the send still waits for it, its
/// deadline.
type Read = {
  kind: Kind;
  chip: ComposerAttachment & { path: string };
  video?: VideoInfo;
  deadline?: ReturnType<typeof setTimeout>;
};

/// The send stops waiting for read `token`; a later answer may still go on its chip.
function settle(reads: Map<symbol, Read>, token: symbol) {
  const read = reads.get(token);
  if (!read?.deadline) return;
  clearTimeout(read.deadline);
  read.deadline = undefined;
  setBusy(read.kind, read.chip.id, token, false);
}

/// Read `token` is over: its answer, whenever it comes, goes nowhere.
function drop(reads: Map<symbol, Read>, token: symbol) {
  settle(reads, token);
  reads.delete(token);
}

/// Whether read `read` may still land: its chip (for a transcript, the chip holding its video) is staged.
function stillStaged(read: Read, staged: ReadonlySet<ComposerAttachment>, attachments: readonly ComposerAttachment[]) {
  if (read.kind === "info") return staged.has(read.chip);
  return staged.size > 0 && attachments.some((chip) => chip.id === read.chip.id && chip.video === read.video);
}

/// Reads the video of each staged video chip that has none yet, while `enabled` (a chat on this Mac,
/// whose files the host may read), and puts it on the chip; then the speech in it (`video.transcript`),
/// which goes on the chip as its `transcript`. Answers how many staged chips are still being read, for
/// the send's wait (useSendWhenAttached): a transcript is waited for only while the video's own
/// deadline (VIDEO_INFO_DEADLINE_MS from its attach) lasts, and a later one still goes on a chip not
/// yet sent. A read's answer goes only on the chip object it was asked for, while that object is still
/// staged and the chat still on this Mac: a chip removed (or removed and added again, a new object with
/// the same id), the chat turning remote or another chat's chips, and the composer going away end it,
/// and a refusal or the deadline ends the wait.
export function useVideoInfo(
  attachments: readonly ComposerAttachment[],
  setAttachments: (update: (current: ComposerAttachment[]) => ComposerAttachment[]) => void,
  enabled: boolean,
): number {
  /// The chips asked (each chip object once: one added again, or replaced without its video, is a
  /// new object and is asked again), the videos whose speech was asked (each answer once), when each
  /// chip's read started (its transcript's wait ends at that read's deadline), and the reads this
  /// composer has out.
  const asked = useRef(new WeakSet<ComposerAttachment>());
  const heard = useRef(new WeakSet<VideoInfo>());
  const since = useRef(new Map<string, number>());
  const out = useRef(new Map<symbol, Read>());
  const shown = useSyncExternalStore(subscribe, busyNow, busyNow);
  useEffect(() => {
    const reads = out.current;
    const requested = asked.current;
    const listened = heard.current;
    return () => {
      // Activity can tear down effects while retaining this hook's state. Retry only reads that
      // were interrupted; a settled response has already left `reads` and remains marked asked.
      for (const [token, { chip, video }] of reads) {
        if (video) listened.delete(video);
        else requested.delete(chip);
        drop(reads, token);
      }
    };
  }, []);
  useEffect(() => {
    const reads = out.current;
    const staged = new Set(enabled ? attachments : []);
    for (const [token, read] of reads) {
      if (stillStaged(read, staged, attachments)) continue;
      drop(reads, token);
      // Asked again if it comes back (the chat back on this Mac).
      if (read.video) heard.current.delete(read.video);
      else asked.current.delete(read.chip);
    }
    if (!enabled) return;
    for (const chip of attachments) {
      if (!isVideoAttachment(chip)) continue;
      if (chip.video) {
        if (!chip.transcript && !heard.current.has(chip.video)) listen(chip, chip.video);
        continue;
      }
      if (asked.current.has(chip)) continue;
      asked.current.add(chip);
      since.current.set(chip.id, Date.now());
      const token = Symbol(chip.id);
      setBusy("info", chip.id, token, true);
      // The send waits no longer than this; a late answer still draws the poster.
      reads.set(token, {
        kind: "info",
        chip,
        deadline: setTimeout(() => settle(reads, token), VIDEO_INFO_DEADLINE_MS),
      });
      void callChipHost("video.info", { src: chip.path }).then(
        (answer) => {
          if (!reads.has(token)) return;
          drop(reads, token);
          const video = parseVideoInfo(answer);
          if (!video) return;
          setAttachments((current) =>
            current.includes(chip)
              ? current.map((staged) => (staged === chip ? { ...staged, video } : staged))
              : current,
          );
        },
        () => {
          // A host refusal leaves the video as a file chip. Finish its read immediately so Stop/Send
          // and the spinner do not wait for the deadline, and handle the rejected native request.
          drop(reads, token);
        },
      );
    }
    /// Asks for the speech in `chip`'s video; the send waits for it until the video's deadline.
    function listen(chip: ComposerAttachment & { path: string }, video: VideoInfo) {
      heard.current.add(video);
      const token = Symbol(chip.id);
      const left = VIDEO_INFO_DEADLINE_MS - (Date.now() - (since.current.get(chip.id) ?? -Infinity));
      const read: Read = { kind: "transcript", chip, video };
      if (left > 0) {
        setBusy("transcript", chip.id, token, true);
        read.deadline = setTimeout(() => settle(reads, token), left);
      }
      reads.set(token, read);
      void callChipHost("video.transcript", { src: chip.path }).then(
        (answer) => {
          if (!reads.has(token)) return;
          drop(reads, token);
          const transcript = parseVideoTranscript(answer);
          if (!transcript) return;
          setAttachments((current) =>
            current.map((staged) =>
              staged.id === chip.id && staged.video === video ? { ...staged, transcript } : staged,
            ),
          );
        },
        () => drop(reads, token),
      );
    }
  }, [attachments, setAttachments, enabled]);
  // Include reads that the effect is about to start. On Activity reveal, a parent's setup
  // continuation can send before the store update from that effect causes another render; and a video
  // whose read just answered is about to be heard.
  const now = Date.now();
  return attachments.filter(
    (chip) =>
      shown.info.has(chip.id) ||
      shown.transcript.has(chip.id) ||
      (enabled &&
        isVideoAttachment(chip) &&
        (chip.video
          ? !chip.transcript &&
            !heard.current.has(chip.video) &&
            now - (since.current.get(chip.id) ?? -Infinity) < VIDEO_INFO_DEADLINE_MS
          : !asked.current.has(chip))),
  ).length;
}
