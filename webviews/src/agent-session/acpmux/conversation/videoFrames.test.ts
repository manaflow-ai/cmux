// l10n-allow-file: test fixtures.
// A `video_frames` call reads as its video and frames (videoFrames.ts): the frames from its image
// blocks, the video's name from its path, its length, size and each frame's time from its note,
// however the note is worded; any other call, a running or failed one, or one with no frame is not one.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { frameLabel, needsTenths, parseTime, videoFrames } from "./videoFrames";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const png = (n: number) => `data:image/png;base64,${btoa(`frame-${n}`)}`;

function call(over: Partial<Tool> = {}): Tool {
  return {
    id: "call-1",
    title: "mcp__cmux__video_frames",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify({ path: "/Users/demo/Chat Uploads/clip one.mp4", count: 3 }),
    output: "Duration: 0:16.4, 1920x1080\n3 frames:\n1. 0:00.0\n2. 0:05.5\n3. 0:11.0",
    images: [png(1), png(2), png(3)],
    ...over,
  } as Tool;
}

test("a finished call reads as its video, length, size and timed frames", () => {
  const video = videoFrames(call())!;
  expect(video.name).toBe("clip one.mp4");
  expect(video.path).toBe("/Users/demo/Chat Uploads/clip one.mp4");
  expect(video.durationMs).toBe(16_400);
  expect([video.width, video.height]).toEqual([1920, 1080]);
  expect(video.frames).toEqual([
    { src: png(1), atMs: 0 },
    { src: png(2), atMs: 5_500 },
    { src: png(3), atMs: 11_000 },
  ]);
  expect(video.text).toContain("3 frames:");
});

test("Codex's {server, tool, arguments} call is one too", () => {
  const video = videoFrames(
    call({
      title: "cmux.video_frames",
      inputSummary: JSON.stringify({ server: "cmux", tool: "video_frames", arguments: { path: "/tmp/a.mov" } }),
    }),
  );
  expect(video?.name).toBe("a.mov");
});

test("frames inside an MCP envelope, with a JSON note and a path that has spaces", () => {
  const note = JSON.stringify({
    path: "/Users/demo/Library/Application Support/cmux/Chat Uploads/demo.mp4",
    durationMs: 8_000,
    width: 1280,
    height: 720,
    frames: [{ atMs: 0 }, { atMs: 4_000 }],
  });
  const output = JSON.stringify({
    content: [
      { type: "text", text: note },
      { type: "image", mimeType: "image/png", data: btoa("a") },
      { type: "image", mimeType: "image/png", data: btoa("b") },
    ],
  });
  const video = videoFrames(call({ inputSummary: "{}", output, images: undefined }))!;
  expect(video.name).toBe("demo.mp4");
  expect(video.durationMs).toBe(8_000);
  expect(video.frames.map((frame) => frame.atMs)).toEqual([0, 4_000]);
  expect(video.text).toBe(note);
});

test("a note's other wordings: frame lines, seconds, a keyed path with spaces", () => {
  const output = [
    "Video: /Users/demo/Chat Uploads/my clip.mov",
    "Length: 12.5s · 640×360",
    "frame 1 at 0.0s",
    "frame 2 at 6.25s",
  ].join("\n");
  const video = videoFrames(call({ inputSummary: "{}", output, images: [png(1), png(2)] }))!;
  expect(video.name).toBe("my clip.mov");
  expect(video.durationMs).toBe(12_500);
  expect([video.width, video.height]).toEqual([640, 360]);
  expect(video.frames.map((frame) => frame.atMs)).toEqual([0, 6_250]);
});

test("not a video_frames call, running, failed, or frameless: no card", () => {
  expect(videoFrames(call({ title: "mcp__cmux__workspace_list" }))).toBeUndefined();
  expect(videoFrames(call({ status: "in_progress" }))).toBeUndefined();
  expect(videoFrames(call({ status: "failed" }))).toBeUndefined();
  expect(videoFrames(call({ images: undefined }))).toBeUndefined();
  expect(
    videoFrames(call({ title: "Bash", kind: "execute", command: "ffmpeg -i clip.mp4 frames/%02d.png" })),
  ).toBeUndefined();
});

test("a note with fewer times than frames leaves the rest untimed", () => {
  const video = videoFrames(call({ output: "1. 0:01.0", images: [png(1), png(2)] }))!;
  expect(video.frames).toEqual([{ src: png(1), atMs: 1_000 }, { src: png(2) }]);
});

test("times parse and print", () => {
  expect(parseTime("1:02.5")).toBe(62_500);
  expect(parseTime("00:01:02.500")).toBe(62_500);
  expect(parseTime("62.5s")).toBe(62_500);
  expect(parseTime("2500ms")).toBe(2_500);
  expect(parseTime("abc")).toBeUndefined();
  expect(frameLabel(62_500, false)).toBe("1:02");
  expect(frameLabel(62_500, true)).toBe("1:02.5");
  expect(frameLabel(3_725_000, false)).toBe("1:02:05");
  expect(needsTenths([{ src: "a", atMs: 1_000 }, { src: "b", atMs: 1_500 }])).toBe(true);
  expect(needsTenths([{ src: "a", atMs: 1_000 }, { src: "b", atMs: 2_500 }])).toBe(false);
});
