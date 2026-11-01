// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-11-01, after a 16 s mp4 attached in a cmux NEXT chat reached Claude Code as "Read the
// linked file with your tools" and its Chat Uploads path, so the agent ran ffmpeg to see it: "i feel
// like cmux-next should give u better tools to deal with this kind of thing". The host read the
// video's frames on attach (`video.info`), and they rode on the chip, but no prompt ever carried
// them: attachmentBlocks sent a link chip as its resource_link alone. Now the frames go after the
// link, with a note naming each one's time, and the sent bubble leaves both out.
import { expect, test } from "bun:test";
import { promptBlocks, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";
import { isVideoAttachment, parseVideoInfo } from "../src/agent-session/acpmux/composer/videoAttachments";
import {
  frameTextOf,
  frameTime,
  rowImageNames,
  withoutFramesNotes,
  withoutVideoFrames,
} from "../src/agent-session/acpmux/composer/videoPrompt";
import { restoreInline } from "../src/agent-session/acpmux/inlinePrompt";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { fitPromptBudget } from "../src/agent-session/acpmux/promptBudget";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000f7";
const UPLOADED = "/Users/dev/Library/Application Support/cmux/Chat Uploads/0190a000-upload/0/screen-demo.mp4";
const FRAMES = [2000, 6000, 10_000, 14_000].map((atMs, index) => ({ atMs, data: btoa(`jpeg-${index}`) }));
const POSTER = "data:image/jpeg;base64,/9j/AA==";
const INFO = { durationMs: 16_000, width: 1920, height: 1080, poster: POSTER, frames: FRAMES };

/// The chip a video dropped in a chat becomes once the host saved it in Chat Uploads (`chat.upload`)
/// and read it (`video.info`), as useVideoInfo puts the answer on it.
async function uploadedVideo(): Promise<ComposerAttachment> {
  const file = new File(["mp4 bytes"], "screen-demo.mp4", { type: "video/mp4" });
  const taken = await intakeFiles([file], { allowImages: true, upload: async () => ({ paths: [UPLOADED] }) });
  const chip = taken.attachments[0]!;
  // The chip knows its host path, so its read runs (not the cause).
  expect(isVideoAttachment(chip)).toBe(true);
  expect(chip.path).toBe(UPLOADED);
  return { ...chip, video: parseVideoInfo(INFO)! };
}

/// A daemon with one idle Claude Code chat that records every prompt it gets.
function fakeDaemon(prompts: Record<string, unknown>[], image = true) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/Users/dev/project",
    title: "demo",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: Date.UTC(2026, 10, 1, 9, 0, 0),
    agentCapabilities: { promptCapabilities: { image, embeddedContext: true } },
  };
  const answer = (method: string, params: Record<string, unknown>) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        prompts.push(params);
        return { stopReason: "end_turn" };
      default:
        return null;
    }
  };
  return () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

/// The newest snapshot's rows, as the transcript draws them.
let rows: AcpmuxRow[] = [];
async function claudeChat(prompts: Record<string, unknown>[], image = true) {
  const chat = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot) => {
      rows = snapshot.rows;
    },
    undefined,
    fakeDaemon(prompts, image),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return chat;
}

type Block = { type: string; text?: string; uri?: string; data?: string; mimeType?: string; name?: string };

test("a Chat Uploads mp4 sent to a Claude Code chat carries its frames, each named for its time", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await claudeChat(prompts);
  await chat.send("what goes wrong in this recording?", [await uploadedVideo()], "p-video");
  const blocks = prompts[0]!.prompt as Block[];
  const link = blocks.findIndex((block) => block.type === "resource_link");
  expect(blocks[link]!.uri).toBe(`file://${UPLOADED.split("/").map(encodeURIComponent).join("/")}`);
  // Right after the link: the note with each frame's time, then the frames in that order.
  expect(blocks[link + 1]).toEqual({
    type: "text",
    text: "Frames from the video screen-demo.mp4 (0:16, 1920×1080), in order, at: 0:02.0, 0:06.0, 0:10.0, 0:14.0.",
  });
  // Each frame: its label with its time, then its image.
  expect(blocks.slice(link + 2)).toEqual(
    FRAMES.flatMap((frame) => [
      { type: "text", text: `screen-demo.mp4 frame at ${frameTime(frame.atMs)}` },
      {
        type: "image",
        mimeType: "image/jpeg",
        data: frame.data,
        name: `screen-demo.mp4 frame at ${frameTime(frame.atMs)}`,
      },
    ]),
  );
  // The bubble shows the prompt and the video, not the note.
  chat.snapshot();
  const row = rows.find((candidate) => candidate.kind === "user");
  expect(row?.text).toContain("what goes wrong in this recording?");
  expect(row?.text).not.toContain("Frames from the video");
});

test("a chat whose agent takes no images gets the video's link without its frames", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await claudeChat(prompts, false);
  await chat.send("look", [await uploadedVideo()], "p-no-images");
  const blocks = prompts[0]!.prompt as Block[];
  expect(blocks.some((block) => block.type === "resource_link")).toBe(true);
  expect(blocks.some((block) => block.type === "image")).toBe(false);
  expect(blocks.some((block) => block.type === "text" && /Frames from the video| frame at /.test(block.text!))).toBe(
    false,
  );
});

test("a video the host could not read goes as its link, as before", async () => {
  const { video: _video, ...plain } = await uploadedVideo();
  const blocks = promptBlocks("look", [plain]) as Block[];
  expect(blocks.map((block) => block.type)).toEqual(["text", "resource_link"]);
});

test("a prompt over the message budget drops the frames before it drops the video", async () => {
  const video = await uploadedVideo();
  const fitted = fitPromptBudget("look", [video], {}, 200);
  expect(fitted[0]!.video?.frames).toEqual([]);
  expect((promptBlocks("look", fitted) as Block[]).some((block) => block.type === "image")).toBe(false);
});

test("the sent bubble leaves out the frames and the note acpmux echoes, and keeps the person's images", () => {
  const note = "Frames from the video screen-demo.mp4 (0:16, 1920×1080), in order, at: 0:02.0, 0:06.0.";
  const row = {
    id: "user-1",
    version: 1,
    at: 0,
    kind: "user",
    text: `what goes wrong?\n\n${note}`,
    images: [
      { id: "a".repeat(64), mimeType: "image/png", name: "Screenshot.png" },
      { id: "b".repeat(64), mimeType: "image/jpeg", name: "screen-demo.mp4 frame at 0:02.0" },
      { id: "c".repeat(64), mimeType: "image/jpeg", name: "screen-demo.mp4 frame at 1:00:06.0" },
    ],
    inlineParts: [
      { kind: "text", text: "what goes wrong?" },
      { kind: "file", name: "screen-demo.mp4", uri: "file:///x/screen-demo.mp4" },
      { kind: "text", text: note },
      { kind: "image", id: "b".repeat(64), mimeType: "image/jpeg", name: "screen-demo.mp4 frame at 0:02.0" },
    ],
  } as AcpmuxRow;
  const shown = withoutVideoFrames(row);
  expect(shown.text).toBe("what goes wrong?");
  expect(shown.images?.map((image) => image.name)).toEqual(["Screenshot.png"]);
  expect(shown.inlineParts?.map((part) => part.kind)).toEqual(["text", "file"]);
  // A person's own line that only looks like it, mid-text, stays.
  expect(withoutFramesNotes(`${note}\nand this`, frameTextOf(rowImageNames(row)))).toBe(`${note}\nand this`);
});

test("a picked frame where a scene starts says so in its label", async () => {
  const chip = await uploadedVideo();
  const frames = [{ atMs: 7200, data: btoa("cut"), scene: true as const }];
  const picked = { ...chip, video: { ...chip.video!, frames, picked: true as const } };
  const blocks = promptBlocks("look", [picked]) as Block[];
  const texts = blocks.filter((block) => block.type === "text").map((block) => block.text);
  expect(texts).toContain("screen-demo.mp4 frame at 0:07.2 (new scene)");
});

test("a video placed mid-text: its note and labels leave Copy and Edit wherever they sit", () => {
  const note = "Frames from the video clip.mov (0:04, 640×360), in order, at: 0:01.0.";
  const row = {
    id: "user-2",
    version: 1,
    at: 0,
    kind: "user",
    text: `before\n${note}\nclip.mov frame at 0:01.0 (new scene)\nafter`,
    images: [{ id: "e".repeat(64), mimeType: "image/jpeg", name: "clip.mov frame at 0:01.0" }],
  } as AcpmuxRow;
  expect(withoutVideoFrames(row).text).toBe("before\nafter");
  // With paste ranges, only the last lines go: no range moves.
  expect(withoutVideoFrames({ ...row, pasted: [{ start: 0, end: 6 }] } as AcpmuxRow).text).toBe(row.text);
});

test("Retry and Edit after a reload rebuild the video's chip with its saved frames, never the note or labels as text", async () => {
  const note = "Frames from the video clip.mov (0:04, 640×360), in order, at: 0:01.0.";
  const row = {
    id: "user-3",
    version: 1,
    at: 0,
    kind: "user",
    text: "look",
    inlineParts: [
      { kind: "text", text: "look " },
      { kind: "file", name: "clip.mov", uri: "file:///tmp/clip.mov", placed: true },
      { kind: "text", text: note },
      { kind: "text", text: "clip.mov frame at 0:01.0 (new scene)" },
      { kind: "image", id: "d".repeat(64), mimeType: "image/jpeg", name: "clip.mov frame at 0:01.0" },
    ],
  } as AcpmuxRow;
  const restored = await restoreInline(row, "look", async () => ({ mimeType: "image/jpeg", data: "eA==" }));
  expect(restored.attachments.map((chip) => [chip.kind, chip.name])).toEqual([["link", "clip.mov"]]);
  expect(restored.input).not.toContain("Frames from the video");
  expect(restored.input).not.toContain("frame at");
  const video = restored.attachments[0]!.video!;
  expect([video.durationMs, video.width, video.height]).toEqual([4000, 640, 360]);
  expect(video.frames).toEqual([{ atMs: 1000, data: "eA==", scene: true }]);
  // Sent again, the agent gets the same note, label and frame.
  const blocks = promptBlocks(restored.input, restored.attachments) as Block[];
  expect(blocks.filter((block) => block.type === "image").map((block) => block.name)).toEqual([
    "clip.mov frame at 0:01.0",
  ]);
  expect(blocks.some((block) => block.type === "text" && block.text === note)).toBe(true);
  expect(blocks.some((block) => block.type === "text" && block.text === "clip.mov frame at 0:01.0 (new scene)")).toBe(
    true,
  );
});

test("the person's own words that only read like a frame's label or note stay, in the bubble, Copy and Edit", async () => {
  const own = "Please inspect the failure in demo.mp4 frame at 0:07.2";
  const note = "Frames from the video other.mp4 (0:04, 640×360), in order, at: 0:01.0.";
  const lonely = { id: "user-4", version: 1, at: 0, kind: "user", text: `look\n${own}` } as AcpmuxRow;
  // No frame image in the prompt: nothing is the agent's.
  expect(withoutVideoFrames(lonely).text).toBe(lonely.text);
  // Another video's frame: only that frame's label and note go, never a look-alike of another time.
  const row = {
    ...lonely,
    text: `look\n${own}\n${note}\nother.mp4 frame at 0:01.0`,
    images: [{ id: "f".repeat(64), mimeType: "image/jpeg", name: "other.mp4 frame at 0:01.0" }],
    inlineParts: [
      { kind: "text", text: `look\n${own}` },
      { kind: "text", text: own.replace("demo.mp4", "other.mp4") },
      { kind: "file", name: "other.mp4", uri: "file:///tmp/other.mp4", placed: true },
      { kind: "text", text: note },
      { kind: "text", text: "other.mp4 frame at 0:01.0" },
      { kind: "image", id: "f".repeat(64), mimeType: "image/jpeg", name: "other.mp4 frame at 0:01.0" },
    ],
  } as AcpmuxRow;
  const shown = withoutVideoFrames(row);
  expect(shown.text).toBe(`look\n${own}`);
  expect(shown.inlineParts?.map((part) => (part.kind === "text" ? part.text : part.kind))).toEqual([
    `look\n${own}`,
    own.replace("demo.mp4", "other.mp4"),
    "file",
  ]);
  const restored = await restoreInline(row, row.text!, async () => ({ mimeType: "image/jpeg", data: "eA==" }));
  expect(restored.input).toContain(own);
  expect(restored.input).toContain(own.replace("demo.mp4", "other.mp4"));
  expect(restored.input).not.toContain("Frames from the video");
});

test("after a reload, two videos of one name each get back their own frames, and an unreadable frame fails the restore", async () => {
  const noteOf = (seconds: number) => `Frames from the video demo.mp4 (0:0${seconds}, 640×360), in order, at: 0:01.0.`;
  const frame = (id: string) =>
    ({ kind: "image", id: id.repeat(64), mimeType: "image/jpeg", name: "demo.mp4 frame at 0:01.0" }) as const;
  const row = {
    id: "user-5",
    version: 1,
    at: 0,
    kind: "user",
    text: "compare",
    inlineParts: [
      { kind: "text", text: "compare " },
      { kind: "file", name: "demo.mp4", uri: "file:///before/demo.mp4", placed: true },
      { kind: "text", text: noteOf(4) },
      { kind: "text", text: "demo.mp4 frame at 0:01.0" },
      frame("1"),
      { kind: "text", text: " with " },
      { kind: "file", name: "demo.mp4", uri: "file:///after/demo.mp4", placed: true },
      { kind: "text", text: noteOf(8) },
      { kind: "text", text: "demo.mp4 frame at 0:01.0" },
      frame("2"),
    ],
  } as AcpmuxRow;
  const bytes = new Map([
    ["1".repeat(64), "b25l"],
    ["2".repeat(64), "dHdv"],
  ]);
  const restored = await restoreInline(row, "compare", async (id) => ({
    mimeType: "image/jpeg",
    data: bytes.get(id)!,
  }));
  expect(
    restored.attachments.map((chip) => [chip.path, chip.video?.durationMs, chip.video?.frames.map((f) => f.data)]),
  ).toEqual([
    ["/before/demo.mp4", 4000, ["b25l"]],
    ["/after/demo.mp4", 8000, ["dHdv"]],
  ]);
  await expect(restoreInline(row, "compare", async () => undefined)).rejects.toThrow();
});

test("after a reload, a frame with no video chip before it (an image of its own) comes back as that image", async () => {
  const row = {
    id: "user-6",
    version: 1,
    at: 0,
    kind: "user",
    text: "again",
    inlineParts: [
      { kind: "text", text: "again " },
      { kind: "image", id: "9".repeat(64), mimeType: "image/jpeg", name: "demo.mp4 frame at 0:01.0" },
    ],
  } as AcpmuxRow;
  const restored = await restoreInline(row, "again", async () => ({ mimeType: "image/jpeg", data: "eA==" }));
  expect(restored.attachments.map((chip) => [chip.kind, chip.name])).toEqual([["image", "demo.mp4 frame at 0:01.0"]]);
});
