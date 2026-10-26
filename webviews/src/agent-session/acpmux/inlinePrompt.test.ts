import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { inlineToken, type ComposerAttachment } from "./attachments";
import type { AcpmuxRow } from "./model";

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
async function connect() {
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
          return { stopReason: "end_turn" };
        }
        if (method === "_acpmux/attachment") return { mimeType: "image/png", data: "AQID" };
        return answer(method, params);
      };
    }
  }
  let rows: AcpmuxRow[] = [];
  let queue: unknown[] = [];
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
    expect(optimistic.inlineParts?.map((part: any) => part.kind)).toEqual([
      "text",
      "image",
      "file",
      "text",
      "file",
      "text",
    ]);
    expect(sent._meta.acpmux.inlineParts.map((part: any) => part.blockIndex)).toEqual([1, 4]);
    io.emit(sent.sessionId, {
      mux: "user_message",
      msg: {
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
      },
    });
    await settle(() => io.rows().some((row) => row.id.startsWith("user-") && row.text === "before\nbetween\nafter"));
    const row = io.rows().find((row) => row.text === "before\nbetween\nafter") as any;
    expect(row.inlineParts[2].companionOf).toBe(row.inlineParts[1].attachmentId);
    expect(row.inlineParts[4].video).toEqual(movie.video);
    const again = await (io.client as any).resendPrompt(row.id, row.text);
    await io.client.send(again.input, again.attachments);
    expect(io.sent[1].prompt).toEqual(sent.prompt);
  } finally {
    io.client.close?.();
  }
});
