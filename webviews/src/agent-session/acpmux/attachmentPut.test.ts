// A prompt's images go to acpmux ahead of it (`_acpmux/attachment_put`) and the prompt names them,
// so no prompt frame carries their bytes: six Retina screenshots in one prompt passed acpmux's
// 16 MiB frame limit and reset the chat's connection (2026-10-20). An acpmux without the method
// gets them inline as before.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { ATTACHMENT_URI, promptBlocks, type ComposerAttachment } from "./attachments";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
const shot = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 68,
  data: PNG,
});

test("a kept image is named by acpmux's id, an image not kept goes inline", () => {
  expect(promptBlocks("look", [shot("a"), shot("b")], new Map([["a", "f00d"]]))).toEqual([
    { type: "text", text: "look" },
    { type: "image", mimeType: "image/png", uri: `${ATTACHMENT_URI}f00d`, name: "a.png" },
    { type: "image", mimeType: "image/png", data: PNG, name: "b.png" },
  ]);
});

/// Yields a macrotask at a time until `done`, at most `tries` times.
const settle = async (done: () => boolean, tries = 500) => {
  for (let n = 0; n < tries && !done(); n += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown> };
type Sent = { method: string; params: any };

/// A client on the mock acpmux that records each request; `withPut` false is an older acpmux.
/// `putsWait` holds every put's answer until it settles.
async function connect(withPut: boolean, putsWait?: Promise<void>) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const sent: Sent[] = [];
  class Recording extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        sent.push({ method, params: structuredClone(params) });
        if (method === "_acpmux/attachment_put" && putsWait) await putsWait;
        const reply = (await answer(method, params)) as any;
        if (method === "initialize" && !withPut) reply._meta.acpmux.extensions = [];
        return reply;
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new Recording() as unknown as WebSocket,
  );
  return { client, sent };
}

test("a prompt's images go ahead of it, and the prompt frame names them", async () => {
  const { client, sent } = await connect(true);
  try {
    await client.send("what is this", [shot("a"), shot("b")], "p-1");
    const puts = sent.filter((frame) => frame.method === "_acpmux/attachment_put");
    expect(puts.map((frame) => frame.params)).toEqual([
      { sessionId: client.selectedSession, mimeType: "image/png", data: PNG },
      { sessionId: client.selectedSession, mimeType: "image/png", data: PNG },
    ]);
    const prompt = sent.find((frame) => frame.method === "session/prompt")!;
    expect(JSON.stringify(prompt.params)).not.toContain(PNG);
    expect(prompt.params.prompt.slice(1).map((block: { uri?: string }) => block.uri)).toEqual([
      `${ATTACHMENT_URI}put-1`,
      `${ATTACHMENT_URI}put-2`,
    ]);
  } finally {
    client.close();
  }
});

test("an acpmux without attachment_put gets the images inline", async () => {
  const { client, sent } = await connect(false);
  try {
    await client.send("what is this", [shot("a")], "p-2");
    expect(sent.some((frame) => frame.method === "_acpmux/attachment_put")).toBe(false);
    const prompt = sent.find((frame) => frame.method === "session/prompt")!;
    expect(prompt.params.prompt[1]).toEqual({ type: "image", mimeType: "image/png", data: PNG, name: "a.png" });
  } finally {
    client.close();
  }
});

test("a prompt still putting its images goes before a prompt sent after it", async () => {
  let open!: () => void;
  const { client, sent } = await connect(true, new Promise<void>((resolve) => (open = resolve)));
  try {
    const first = client.send("look at this", [shot("a")], "p-first");
    await settle(() => sent.some((frame) => frame.method === "_acpmux/attachment_put"));
    const second = client.send("and fix it", [], "p-second");
    // Long enough for a prompt with nothing to put to be written, were it not waiting.
    await settle(() => false, 20);
    // The second waits for the first, whose put has no answer yet.
    expect(sent.filter((frame) => frame.method === "session/prompt")).toEqual([]);
    open();
    await Promise.all([first, second]);
    expect(
      sent.filter((frame) => frame.method === "session/prompt").map((frame) => frame.params._meta.acpmux.promptId),
    ).toEqual(["p-first", "p-second"]);
  } finally {
    client.close();
  }
});

test("a PDF over the put cap is not put: its put would pass the frame limit", async () => {
  const { MAX_PUT_BYTES } = await import("./direct");
  const { client, sent } = await connect(true);
  const big: ComposerAttachment = {
    id: "big",
    kind: "document",
    name: "big.pdf",
    mimeType: "application/pdf",
    size: MAX_PUT_BYTES + 3,
    data: "A".repeat(Math.ceil((MAX_PUT_BYTES + 3) / 3) * 4),
  };
  try {
    await client.send("read this", [shot("a"), big], "p-big");
    const puts = sent.filter((frame) => frame.method === "_acpmux/attachment_put");
    expect(puts.map((frame) => frame.params.mimeType)).toEqual(["image/png"]);
  } finally {
    client.close();
  }
});
