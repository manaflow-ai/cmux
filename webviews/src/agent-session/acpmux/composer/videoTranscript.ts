// The speech in an attached video, for the agent (Leo, 2026-11-01, after the agent saw only sampled
// frames of a recording: "i feel like cmux-next should give u better tools to deal with this kind of
// thing"). The host transcribes it on this Mac (`video.transcript`, AgentPaneVideoTranscript.swift):
// never with a prompt or a model download, the first ten minutes at most, and nothing for audio with
// no speech. The page asks once the video's own read answered (videoAttachments.ts), and the prompt
// carries the transcript as its hidden context (`_meta.acpmux.context`): the agent reads it, while the
// sent bubble, the chat list and the title show only what the person wrote.
//
// l10n-allow-file: the context is text for the agent, not the person, so it is not localized.
import type { ComposerAttachment } from "../attachments";

export type VideoTranscriptSegment = { startMs: number; endMs: number; text: string };

/// What the host answers (AgentPaneVideoTranscript.Transcript): the lines heard, with their times in
/// the video, and how much of it was heard.
export type VideoTranscript = { segments: VideoTranscriptSegment[]; heardMs: number; durationMs: number };

/// The most lines a chip keeps, whatever the host says.
const MAX_SEGMENTS = 2_000;
/// acpmux's limit on a prompt's whole hidden context (prompt_context.rs MAX_BYTES).
export const MAX_CONTEXT_BYTES = 16 * 1024;

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0;

/// The host's `video.transcript` answer, checked; undefined for no speech, a refusal or an older host.
export function parseVideoTranscript(value: unknown): VideoTranscript | undefined {
  const raw = value as Partial<Record<keyof VideoTranscript, unknown>> | null | undefined;
  if (!raw || !Array.isArray(raw.segments) || !finite(raw.heardMs) || !finite(raw.durationMs)) return undefined;
  const segments = raw.segments.flatMap((segment: unknown) => {
    const { startMs, endMs, text } = (segment ?? {}) as Partial<Record<keyof VideoTranscriptSegment, unknown>>;
    return finite(startMs) && finite(endMs) && endMs >= startMs && typeof text === "string" && text.trim()
      ? [{ startMs, endMs, text: text.trim() }]
      : [];
  });
  if (!segments.length) return undefined;
  return { segments: segments.slice(0, MAX_SEGMENTS), heardMs: raw.heardMs, durationMs: raw.durationMs };
}

/// `ms` as m:ss (h:mm:ss past an hour).
export function clock(ms: number): string {
  const total = Math.floor(ms / 1000);
  const seconds = String(total % 60).padStart(2, "0");
  const minutes = Math.floor(total / 60);
  return minutes >= 60 ? `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}:${seconds}` : `${minutes}:${seconds}`;
}

const bytes = (text: string) => new TextEncoder().encode(text).length;

/// One video's transcript as a context element, cut to `budget` bytes at whole lines (with a note
/// that the rest was left out); undefined when not even its header fits.
function videoContext(name: string, transcript: VideoTranscript, budget: number): string | undefined {
  const heard =
    transcript.heardMs + 1000 < transcript.durationMs
      ? ` Only the first ${clock(transcript.heardMs)} of its ${clock(transcript.durationMs)} was heard.`
      : "";
  const open = `<cmux-video-transcript-context>\nThe speech in the attached video ${JSON.stringify(name)}, transcribed on the person's Mac; times are into the video.${heard} The person did not type this note; do not quote it.\n`;
  const close = "</cmux-video-transcript-context>";
  const cut = "[the rest of the transcript was left out]\n";
  let used = bytes(open) + bytes(close) + bytes(cut);
  if (used > budget) return undefined;
  const lines: string[] = [];
  for (const segment of transcript.segments) {
    const line = `[${clock(segment.startMs)}-${clock(segment.endMs)}] ${segment.text}\n`;
    const size = bytes(line);
    if (used + size > budget) return open + lines.join("") + cut + close;
    used += size;
    lines.push(line);
  }
  return open + lines.join("") + close;
}

/// The hidden context a prompt carries: `base` (the chat's workspace context, when it has one) and
/// the transcript of each attached video that has one, within acpmux's limit; undefined when there
/// is nothing. Like the workspace context it starts on its own line.
export function promptContext(base: string | undefined, attachments: readonly ComposerAttachment[]): string | undefined {
  let context = base ?? "";
  for (const chip of attachments) {
    if (!chip.transcript) continue;
    const separator = "\n\n";
    const piece = videoContext(chip.name, chip.transcript, MAX_CONTEXT_BYTES - bytes(context) - bytes(separator));
    if (piece) context += separator + piece;
  }
  return context || undefined;
}
