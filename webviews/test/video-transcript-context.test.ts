// Leo, 2026-11-01, after the agent saw only sampled frames of a recording: "i feel like cmux-next
// should give u better tools to deal with this kind of thing". An attached video's speech, heard on
// this Mac (`video.transcript`), goes to the agent as the prompt's hidden context: checked, with its
// times, within acpmux's 16 KiB limit, and beside the chat's workspace context when it has one.
import { expect, test } from "bun:test";
import { linkAttachment } from "../src/agent-session/acpmux/attachments";
import {
  MAX_CONTEXT_BYTES,
  clock,
  parseVideoTranscript,
  promptContext,
} from "../src/agent-session/acpmux/composer/videoTranscript";

const SPEECH = {
  segments: [
    { startMs: 1_200, endMs: 4_800, text: "The sidebar jumps when I resize the window." },
    { startMs: 65_000, endMs: 70_250, text: "See, right there." },
  ],
  heardMs: 600_000,
  durationMs: 1_513_000,
};
const video = (name = "Screen Recording.mov") => ({
  ...linkAttachment(`/Users/dev/Desktop/${name}`, false),
  mimeType: "video/quicktime",
  size: 1,
});
const bytes = (text: string) => new TextEncoder().encode(text).length;

test("the host's answer is checked: lines with words and times, or nothing", () => {
  expect(parseVideoTranscript(SPEECH)).toEqual(SPEECH);
  expect(parseVideoTranscript({ segments: [] })).toBeUndefined();
  expect(parseVideoTranscript({ ...SPEECH, segments: [] })).toBeUndefined();
  expect(parseVideoTranscript(undefined)).toBeUndefined();
  expect(parseVideoTranscript({ ...SPEECH, heardMs: -1 })).toBeUndefined();
  expect(
    parseVideoTranscript({
      ...SPEECH,
      segments: [
        ...SPEECH.segments,
        { startMs: 5, endMs: 1, text: "backwards" },
        { startMs: 1, endMs: 2, text: "  " },
        { startMs: 1, endMs: 2 },
        "x",
      ],
    })?.segments,
  ).toEqual(SPEECH.segments);
});

test("times read as m:ss, and h:mm:ss past an hour", () => {
  expect(clock(0)).toBe("0:00");
  expect(clock(65_400)).toBe("1:05");
  expect(clock(3_725_000)).toBe("1:02:05");
});

test("a prompt with a heard video carries its transcript as hidden context, with times and how much was heard", () => {
  expect(promptContext(undefined, [video()])).toBeUndefined();
  const context = promptContext(undefined, [{ ...video(), transcript: SPEECH }])!;
  expect(context.trimStart().startsWith("<cmux-video-transcript-context>")).toBe(true);
  expect(context.trimEnd().endsWith("</cmux-video-transcript-context>")).toBe(true);
  expect(context).toContain('"Screen Recording.mov"');
  expect(context).toContain("[0:01-0:04] The sidebar jumps when I resize the window.\n");
  expect(context).toContain("[1:05-1:10] See, right there.\n");
  expect(context).toContain("Only the first 10:00 of its 25:13 was heard.");
  // A video heard to its end says nothing about a cut.
  const whole = promptContext(undefined, [{ ...video(), transcript: { ...SPEECH, durationMs: 600_000 } }])!;
  expect(whole).not.toContain("Only the first");
});

test("the workspace context comes first, and every video's transcript fits acpmux's limit", () => {
  const workspace = "\n\n<cmux-workspace-context>\nwhere this chat is\n</cmux-workspace-context>";
  expect(promptContext(workspace, [])).toBe(workspace);
  const long = {
    ...SPEECH,
    segments: Array.from({ length: 1_500 }, (_, at) => ({
      startMs: at * 400,
      endMs: at * 400 + 300,
      text: "one two three four five six seven eight nine ten",
    })),
  };
  const context = promptContext(workspace, [
    { ...video("a.mov"), transcript: long },
    { ...video("b.mov"), transcript: SPEECH },
  ])!;
  expect(context.startsWith(workspace)).toBe(true);
  expect(bytes(context)).toBeLessThanOrEqual(MAX_CONTEXT_BYTES);
  // The long one is cut at a whole line, and says so; the second has no room left.
  expect(context).toContain("[the rest of the transcript was left out]");
  expect(context).toContain('"a.mov"');
  expect(context.match(/<cmux-video-transcript-context>/g)?.length).toBe(1);
});
