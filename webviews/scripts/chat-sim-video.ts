// Cut and stack chat-sim videos (Leo, 2026-11-22: "that clip goes for 1 minute long and the only relevant
// and differentiating bit is at the last 10 seconds. so you guys need to be able to set these scenarios up
// faster and better and record better."). Playwright records a whole page from its first frame; a
// windowed run (--start/--end) marks where its window began, and these cut each video to that window,
// label it and, for several arms, put them side by side in one clip.
//
// It needs a full ffmpeg (libx264, a vp8 decoder): CHAT_SIM_FFMPEG, else `ffmpeg` on PATH. Playwright's
// own ffmpeg only encodes its recording. With none, the videos stay whole and the window's offset is
// printed instead.
import { spawnSync } from "node:child_process";

/** A full ffmpeg's path, or undefined. */
export function findFfmpeg(): string | undefined {
  for (const candidate of [process.env.CHAT_SIM_FFMPEG, "ffmpeg"]) {
    if (!candidate) continue;
    const probe = spawnSync(candidate, ["-hide_banner", "-encoders"], { encoding: "utf8" });
    if (probe.status === 0 && probe.stdout.includes("libx264")) return candidate;
  }
  return undefined;
}

export type Clip = {
  /** The whole recording (webm). */
  file: string;
  /** Where the window starts in it, s. */
  startS: number;
  /** How long the window runs, s (undefined: to the end). */
  seconds?: number;
  /** The text drawn over its top left corner. */
  label: string;
};

// drawtext's own escapes: a label is plain words, so only these need it.
const drawtextText = (text: string) => text.replace(/[\\:'%]/g, (c) => `\\${c}`);

/** One clip per input, cut to its window and labelled, side by side in OUT (mp4); the shortest sets the length. */
export function stackClips(ffmpeg: string, clips: readonly Clip[], out: string): void {
  const inputs = clips.flatMap((clip) => [
    "-ss",
    clip.startS.toFixed(3),
    ...(clip.seconds === undefined ? [] : ["-t", clip.seconds.toFixed(3)]),
    "-i",
    clip.file,
  ]);
  const labelled = clips.map(
    (clip, index) =>
      `[${index}:v]setpts=PTS-STARTPTS,drawtext=text='${drawtextText(clip.label)}':x=16:y=16:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=8[v${index}]`,
  );
  const stack =
    clips.length > 1
      ? `${clips.map((_, index) => `[v${index}]`).join("")}hstack=inputs=${clips.length}:shortest=1[out]`
      : "[v0]null[out]";
  const result = spawnSync(
    ffmpeg,
    [
      "-y",
      "-loglevel",
      "error",
      ...inputs,
      "-filter_complex",
      [...labelled, stack].join(";"),
      "-map",
      "[out]",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "28",
      "-pix_fmt",
      "yuv420p",
      "-an",
      out,
    ],
    { encoding: "utf8" },
  );
  if (result.status !== 0) throw new Error(`ffmpeg (${out}): ${result.stderr || result.error?.message}`);
}
