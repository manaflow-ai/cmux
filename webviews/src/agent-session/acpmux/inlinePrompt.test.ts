import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { inlineToken, type ComposerAttachment } from "./attachments";
import type { AcpmuxRow, QueuedPrompt } from "./model";
import { takeBackSteer } from "./conversation/PendingSteer";
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});
const settle = async (done: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error("timed out waiting for prompt");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};
type Hooks = { answer: (method: string, params: any) => Promise<unknown>; emit: (target: string, step: any) => void };
async function connect(hold = false, refuse = false) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const sent: any[] = [];
  let emit: Hooks["emit"] | undefined;
  class Host extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      emit = hooks.emit.bind(this);
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "session/prompt") {
          sent.push(params);
          if (refuse) throw new Error("attachment test refused");
          return hold ? new Promise(() => undefined) : { stopReason: "end_turn" };
        }
        if (method === "_acpmux/attachment") return { mimeType: "image/png", data: "AQID" };
        return answer(method, params);
      };
    }
  }
  let rows: AcpmuxRow[] = [];
  let queue: QueuedPrompt[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows;
      queue = snapshot.queue ?? [];
    },
    undefined,
    () => new Host() as unknown as WebSocket,
  );
  return {
    client,
    sent,
    emit: (target: string, step: any) => emit!(target, step),
    rows: () => rows,
    queue: () => queue,
  };
}
const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: "one.png",
  mimeType: "image/png",
  size: 3,
  data: "AQID",
  originalPath: "/tmp/one.png",
});
const movie: ComposerAttachment = {
  id: "movie",
  kind: "link",
  name: "clip.mp4",
  mimeType: "video/mp4",
  size: 12,
  path: "/tmp/clip.mp4",
  video: { durationMs: 1000, width: 20, height: 10, poster: "data:image/jpeg;base64,AQID", frames: [] },
};
const shape = (blocks: any[]) => blocks.map((block) => (block.type === "text" ? block.text : block.type));
test("send retains ID-bound image and video order through a reply before echo", async () => {
  const io = await connect();
  try {
    const input = `before${inlineToken("one")}between${inlineToken("movie")}after`;
    await io.client.send(input, [movie, image("one")]);
    const sent = io.sent[0];
    expect(shape(sent.prompt)).toEqual(["before", "image", "resource_link", "between", "resource_link", "after"]);
    const optimistic = io.rows().find((row) => row.id.startsWith("local-")) as any;
    expect(optimistic.inlineParts?.map((part: any) => part.kind).join(",")).toBe("text,image,file,text,file,text");
    expect(sent._meta.acpmux.inlineParts.map((part: any) => part.blockIndex)).toEqual([1, 2, 4]);
    const record = {
      promptId: sent._meta.acpmux.promptId,
      text: "before\nbetween\nafter",
      images: [{ id: "durable-one", mimeType: "image/png" }],
      inlineParts: [
        { kind: "text", text: "before" },
        { kind: "image", id: "durable-one", mimeType: "image/png" },
        { kind: "file", name: "one.png", uri: "file:///tmp/one.png" },
        { kind: "text", text: "between" },
        { kind: "file", name: "clip.mp4", uri: "file:///tmp/clip.mp4" },
        { kind: "text", text: "after" },
      ],
    };
    io.emit(sent.sessionId, { mux: "user_message", msg: record });
    await settle(() => io.rows().some((row) => row.id.startsWith("user-") && row.text === "before\nbetween\nafter"));
    const row = io.rows().find((row) => row.text === "before\nbetween\nafter") as any;
    expect(row.inlineParts[2].companionOf).toBe(row.inlineParts[1].blockIndex);
    expect(row.inlineParts[4].video).toEqual(movie.video);
    let restored: { input: string; attachments: ComposerAttachment[] } | undefined;
    expect(
      await takeBackSteer(
        { ...row, steer: "waiting", steerPromptId: "steer" },
        {
          withdraw: async () => true,
          attachments: (id) => io.client.promptAttachments(id),
          draft: (id, text) => io.client.resendPrompt(id, text),
          restore: (input, attachments) => {
            restored = { input, attachments };
          },
        },
      ),
    ).toBe(true);
    expect(restored?.input).toBe(input);
    const again = await io.client.resendPrompt(row.id, row.text);
    await io.client.send(again.input, again.attachments);
    expect(io.sent[1].prompt).toEqual(sent.prompt);
  } finally {
    io.client.close?.();
  }
});
test("history retry preserves repeated image occurrences and a video link", async () => {
  const io = await connect();
  try {
    await io.client.send("warm");
    const sessionId = io.sent[0].sessionId;
    io.emit(sessionId, {
      mux: "user_message",
      msg: {
        text: "one\ntwo\nthree",
        images: [
          { id: "same-sha", mimeType: "image/png" },
          { id: "same-sha", mimeType: "image/png" },
        ],
        inlineParts: [
          { kind: "image", id: "same-sha", mimeType: "image/png", blockIndex: 0 },
          { kind: "file", name: "one.png", uri: "file:///tmp/one.png", companionOf: 0 },
          { kind: "text", text: "one" },
          { kind: "file", name: "clip.mp4", uri: "file:///tmp/clip.mp4" },
          { kind: "text", text: "two" },
          { kind: "image", id: "same-sha", mimeType: "image/png" },
          { kind: "text", text: "three" },
        ],
      },
    });
    await settle(() => io.rows().some((row) => row.text === "one\ntwo\nthree"));
    const row = io.rows().find((row) => row.text === "one\ntwo\nthree")!;
    const draft = await io.client.resendPrompt(row.id, row.text!);
    expect(new Set(draft.attachments.map((a) => a.id)).size).toBe(3);
    await io.client.send(draft.input, draft.attachments);
    expect(shape(io.sent[1].prompt).join(",")).toBe("image,resource_link,one,resource_link,two,image,three");
    expect(io.sent[1].prompt[3].uri).toBe("file:///tmp/clip.mp4");
  } finally {
    io.client.close?.();
  }
});
test("an inline paste goes exactly once on retry and edits keep whole tokens", async () => {
  const io = await connect();
  try {
    const paste: ComposerAttachment = {
      id: "paste",
      kind: "pasted",
      name: "paste",
      mimeType: "text/plain",
      size: 6,
      text: "pasted",
    };
    await io.client.send(`a${inlineToken("paste")}b${inlineToken("one")}c`, [image("one"), paste]);
    const sent = io.sent[0];
    expect(shape(sent.prompt)).toEqual(["a", "pasted", "b", "image", "resource_link", "c"]);
    io.emit(sent.sessionId, {
      mux: "user_message",
      msg: { promptId: sent._meta.acpmux.promptId, text: "a\npasted\nb\nc" },
    });
    await settle(() => io.rows().some((row) => row.id.startsWith("user-") && row.text === "a\npasted\nb\nc"));
    const row = io.rows().find((row) => row.text === "a\npasted\nb\nc")!;
    const draft = await io.client.resendPrompt(row.id, row.text!);
    await io.client.send(draft.input, draft.attachments);
    expect(io.sent[1].prompt).toEqual(sent.prompt);
    const edited = await io.client.resendPrompt(row.id, "edited");
    expect(edited.input).toContain(inlineToken("one"));
    expect(edited.input).not.toContain(inlineToken("paste"));
  } finally {
    io.client.close?.();
  }
});
test("refused Retry and Edit retain every screenshot and video preview in strip mode", async () => {
  const io = await connect(false, true);
  const attachments = [...Array.from({ length: 8 }, (_, index) => image(`screen-${index}`)), movie];
  try {
    await io.client.send("plain", attachments).catch(() => undefined);
    await settle(() => io.rows().some((row) => row.failed));
    const row = io.rows().find((row) => row.failed)!;
    expect(io.sent[0]._meta.acpmux.inlineParts).toHaveLength(8);
    expect(io.sent[0]._meta.acpmux.inlineParts.every((part: any) => part.companionOf + 1 === part.blockIndex)).toBe(
      true,
    );
    expect(row.inlineParts).toBeUndefined();
    expect(row.images).toHaveLength(8);
    expect(row.images?.every((image) => image.src === "data:image/png;base64,AQID")).toBe(true);
    const draft = await io.client.resendPrompt(row.id, row.text!);
    expect(draft).toEqual({ input: "plain", attachments });
    await io.client.retryPrompt(row.id).catch(() => undefined);
    await settle(() => io.sent.length === 2 && io.rows().some((row) => row.failed));
    expect(io.sent[1].prompt).toEqual(io.sent[0].prompt);
    expect(io.sent[1].prompt.filter((block: any) => block.type === "image")).toHaveLength(8);
    expect(io.client.takeFailedPrompt(row.id)).toEqual({ input: "plain", attachments });
  } finally {
    io.client.close?.();
  }
});
test("queue acceptance retains ordered metadata before the prompt reply", async () => {
  const io = await connect(true);
  try {
    void io.client.send(`a${inlineToken("movie")}b`, [movie]).catch(() => undefined);
    await settle(() => io.sent.length === 1);
    const sent = io.sent[0];
    io.emit(sent.sessionId, {
      mux: "queued",
      msg: {
        promptId: sent._meta.acpmux.promptId,
        text: "a\nb",
        inlineParts: [
          { kind: "text", text: "a" },
          { kind: "file", name: "clip.mp4", uri: "file:///tmp/clip.mp4" },
          { kind: "text", text: "b" },
        ],
      },
    });
    await settle(() => io.queue().some((entry) => entry.id === sent._meta.acpmux.promptId));
    expect(io.queue()[0].inlineParts?.[1]).toMatchObject({ video: movie.video });
    io.emit(sent.sessionId, {
      mux: "queue_updated",
      msg: { promptId: sent._meta.acpmux.promptId, text: "removed", inlineParts: [{ kind: "text", text: "removed" }] },
    });
    await settle(() => io.queue()[0]?.prompt === "removed");
    expect(io.queue()[0].inlineParts?.some((part) => part.kind !== "text")).toBe(false);
    io.emit(sent.sessionId, {
      mux: "user_message",
      msg: { promptId: sent._meta.acpmux.promptId, text: "removed", inlineParts: [{ kind: "text", text: "removed" }] },
    });
    await settle(() => io.rows().some((row) => row.text === "removed"));
    const row = io.rows().find((row) => row.text === "removed")!;
    expect(await io.client.resendPrompt(row.id, row.text!)).toEqual({ input: "removed", attachments: [] });
  } finally {
    io.client.close?.();
  }
});

test("strip echo Retry and Edit retain local bytes, original path and video", async () => {
  const io = await connect();
  const attachments = [image("strip"), movie];
  try {
    await io.client.send("strip", attachments);
    const sent = io.sent[0];
    const original = sent.prompt.findIndex((block: any) => block.uri === "file:///tmp/one.png");
    expect(sent._meta.acpmux.inlineParts).toContainEqual({
      kind: "file",
      blockIndex: original,
      name: "one.png",
      companionOf: original - 1,
    });
    io.emit(sent.sessionId, {
      mux: "user_message",
      msg: {
        promptId: sent._meta.acpmux.promptId,
        text: "strip",
        inlineParts: [
          { kind: "text", text: "strip" },
          { kind: "image", id: "durable", mimeType: "image/png" },
          { kind: "file", name: "one.png", uri: "file:///tmp/one.png" },
          { kind: "file", name: "clip.mp4", uri: "file:///tmp/clip.mp4" },
        ],
      },
    });
    await settle(() => io.rows().some((r) => r.id.startsWith("user-") && r.text === "strip"));
    const row = io.rows().find((r) => r.id.startsWith("user-") && r.text === "strip")!;
    expect(await io.client.resendPrompt(row.id, "strip")).toEqual({ input: "strip", attachments });
    expect(await io.client.resendPrompt(row.id, "edited")).toEqual({ input: "edited", attachments });
  } finally {
    io.client.close?.();
  }
});

test("strip-mode files keep type and byte count in the actual prompt metadata and echoed row", async () => {
  const io = await connect();
  const file: ComposerAttachment = {
    id: "pem",
    kind: "link",
    name: "production-key.pem",
    mimeType: "application/x-pem-file",
    size: 2048,
    path: "/tmp/production-key.pem",
  };
  try {
    await io.client.send("Use this key", [file]);
    const sent = io.sent[0];
    const blockIndex = sent.prompt.findIndex((block: any) => block.type === "resource_link");
    expect(sent._meta.acpmux.inlineParts).toEqual([
      { kind: "file", blockIndex, name: file.name, mimeType: file.mimeType, size: 2048 },
    ]);
    io.emit(sent.sessionId, {
      mux: "user_message",
      msg: {
        seq: 401,
        at: 1,
        promptId: sent._meta.acpmux.promptId,
        text: "Use this key",
        inlineParts: [
          { kind: "text", text: "Use this key" },
          { kind: "file", name: file.name, mimeType: file.mimeType, size: 2048, uri: "file:///tmp/production-key.pem" },
        ],
      },
    });
    await settle(() =>
      io.rows().some((row) => row.inlineParts?.some((part) => part.kind === "file" && part.name === file.name)),
    );
    expect(
      io.rows().find((row) => row.inlineParts?.some((part) => part.kind === "file" && part.name === file.name))
        ?.inlineParts?.[1],
    ).toMatchObject({
      kind: "file",
      name: file.name,
      size: 2048,
    });
  } finally {
    io.client.close();
  }
});

test("path-only files omit an empty MIME so the daemon accepts their display metadata", async () => {
  const io = await connect();
  try {
    await io.client.send("Use this", [
      { id: "key", kind: "link", name: "key.pem", path: "/tmp/key.pem", mimeType: "", size: 0 },
    ]);
    const sent = io.sent[0];
    expect(sent._meta.acpmux.inlineParts).toEqual([{ kind: "file", name: "key.pem", blockIndex: 1 }]);
  } finally {
    io.client.close?.();
  }
});
