// Attachments with no saved original (an older draft's PDF, a recording, an image whose original
// failed to upload) went inline whatever their sum, so a prompt of them could still pass acpmux's
// one message (Leo, 2026-10-31: "this is completely hardlocked bc of message size"). Past the
// budget the largest of them upload at the Send, under the Send's ticket (the host's
// chat.upload.begin holds it instead of spending the gesture), and go as links.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { promptBlocks, type ComposerAttachment, type PromptBlock } from "./attachments";
import { PROMPT_INLINE_BUDGET, inlineBytes, uploadsToFit } from "./promptBudget";
import { uploadForSend } from "./sendUploads";
import { setNativeHost } from "./native";

const MIB = 1024 * 1024;
const pdf = (index: number, bytes = 9 * MIB): ComposerAttachment => ({
  id: `pdf-${index}`,
  kind: "document",
  name: `Report ${index}.pdf`,
  mimeType: "application/pdf",
  size: bytes,
  data: "A".repeat(Math.ceil(bytes / 3) * 4),
});

test("past the budget the largest attachments with no saved original are picked to upload, largest first", () => {
  const two = [pdf(1, 12 * MIB), pdf(2, 13 * MIB)];
  expect(inlineBytes(promptBlocks("read these", two))).toBeGreaterThan(PROMPT_INLINE_BUDGET);
  expect(uploadsToFit("read these", two).map((chip) => chip.id)).toEqual(["pdf-2"]);
  // Under the budget nothing uploads.
  expect(uploadsToFit("read this", [pdf(1, 2 * MIB)])).toEqual([]);
});

test("a send's upload begins every file under the Send's ticket, one by one with no batch", async () => {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const call = async (method: string, params: Record<string, unknown>): Promise<unknown> => {
    calls.push({ method, params });
    if (method === "chat.upload.begin")
      return { token: `t-${String(params.name)}`, size: params.size, chunkSize: 512 * 1024 };
    if (method === "chat.upload.chunk")
      return { offset: (params.offset as number) + atob(params.data as string).length };
    if (method === "chat.upload.finish") return { path: `/Users/me/.cmux/uploads/${String(params.token).slice(2)}` };
    return {};
  };
  const sent = await uploadForSend(
    [pdf(1, 600), pdf(2, 999)],
    { sessionId: "s-1", promptId: "p-1", ticket: "k-1" },
    call,
  );
  expect(sent).toEqual({
    ticket: "k-1",
    attachments: [
      expect.objectContaining({ kind: "link", saved: true }),
      expect.objectContaining({ kind: "link", saved: true }),
    ],
  });
  expect(calls.map((entry) => entry.method)).not.toContain("transport.gesture");
  const begins = calls.filter((entry) => entry.method === "chat.upload.begin");
  expect(begins).toHaveLength(2);
  for (const begin of begins) {
    expect(begin.params).toMatchObject({ sessionId: "s-1", promptId: "p-1", ticket: "k-1" });
    expect(begin.params).not.toHaveProperty("batch");
    expect(begin.params).not.toHaveProperty("batchToken");
  }
  const link = (sent as { attachments: ComposerAttachment[] }).attachments[1]!;
  expect(link).toMatchObject({
    id: "pdf-2",
    path: "/Users/me/.cmux/uploads/Report 2.pdf",
    mimeType: "application/pdf",
    size: 999,
  });
});

test("an upload that fails fails the send with its words", async () => {
  const failing = async (method: string): Promise<unknown> => {
    if (method === "chat.upload.begin") throw new Error("The disk is full.");
    return {};
  };
  const sent = await uploadForSend([pdf(2, 1000)], { sessionId: "s-1", promptId: "p-1", ticket: "k-1" }, failing);
  expect(sent).toEqual({ error: "The disk is full." });
});

// The client: three 9 MiB PDFs (12 MiB of base64 each) go in one message under the budget, the
// largest past it as links, under a send ticket bound to the chat.
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  setNativeHost(undefined);
});

async function client() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const prompts: { sessionId: string; prompt: PromptBlock[]; meta: Record<string, unknown> }[] = [];
  const intents: Record<string, unknown>[] = [];
  setNativeHost(async (method, params) => {
    if (method !== "transport.gesture") throw new Error("not in this test");
    intents.push((params.intent as { params: Record<string, unknown> }).params);
    return { ticket: `k-${intents.length}` };
  });
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt")
          prompts.push({ sessionId: params.sessionId, prompt: params.prompt, meta: params._meta });
        return answer(method, params);
      };
    }
  }
  const pane = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  const uploaded: { names: string[]; tickets: string[] } = { names: [], tickets: [] };
  pane.uploadForSend = async (chips, prompt) => {
    uploaded.names.push(...chips.map((chip) => chip.name));
    uploaded.tickets.push(prompt.ticket);
    return {
      ticket: prompt.ticket,
      attachments: chips.map((chip) => ({
        ...chip,
        kind: "link" as const,
        data: undefined,
        path: `/up/${chip.name}`,
        saved: true,
      })),
    };
  };
  // A chat to send in: the first send starts it.
  await pane.send("hello").catch(() => undefined);
  return { pane, prompts, intents, uploaded };
}

test("past the budget a send to a shown chat uploads the largest under its chat-bound ticket and goes as links", async () => {
  const { pane, prompts, intents, uploaded } = await client();
  try {
    const sessionId = pane.selectedSession;
    expect(sessionId).toBeTruthy();
    await pane.send("read these", [pdf(1), pdf(2), pdf(3)]).catch(() => undefined);
    expect(uploaded.names).toHaveLength(1);
    // The ticket names the chat it was reserved in.
    expect(intents.at(-1)).toMatchObject({ sessionId });
    const sent = prompts.at(-1)!;
    expect(inlineBytes(sent.prompt)).toBeLessThanOrEqual(PROMPT_INLINE_BUDGET);
    expect(sent.prompt.filter((block) => block.type === "document")).toHaveLength(2);
    expect(
      sent.prompt.some(
        (block) => block.type === "resource_link" && block.uri.endsWith(encodeURIComponent(uploaded.names[0]!)),
      ),
    ).toBe(true);
    // The prompt goes under the ticket its upload held.
    expect(sent.meta.cmuxGesture).toBe(uploaded.tickets[0]);
  } finally {
    pane.close?.();
  }
});

test("a send under a ticket bound to no chat (a held prompt's) uploads nothing", async () => {
  const { pane, uploaded } = await client();
  try {
    await pane
      .send("read these", [pdf(1), pdf(2), pdf(3)], crypto.randomUUID(), undefined, "held")
      .catch(() => undefined);
    expect(uploaded.names).toEqual([]);
  } finally {
    pane.close?.();
  }
});

test("a send with files to upload whose ticket comes after its chat was left goes back to its sender", async () => {
  const { pane, prompts, uploaded } = await client();
  try {
    expect(pane.selectedSession).toBeTruthy();
    let answer: (reply: { ticket: string }) => void = () => {};
    setNativeHost(async (method) => {
      if (method !== "transport.gesture") throw new Error("not in this test");
      return new Promise((resolve) => (answer = resolve));
    });
    const before = prompts.length;
    const sending = pane.send("read these", [pdf(1), pdf(2), pdf(3)]).then(
      () => "sent",
      (error: unknown) => (error instanceof Error ? error.message : String(error)),
    );
    await Promise.resolve();
    pane.leave();
    answer({ ticket: "k-late" });
    expect(await sending).not.toBe("sent");
    expect(uploaded.names).toEqual([]);
    expect(prompts.length).toBe(before);
  } finally {
    pane.close?.();
  }
});

test("a text-only send whose ticket comes after its chat was left goes to its own chat, never the one shown", async () => {
  const { pane, prompts } = await client();
  try {
    const sessionId = pane.selectedSession;
    expect(sessionId).toBeTruthy();
    let answer: (reply: { ticket: string }) => void = () => {};
    setNativeHost(async (method) => {
      if (method !== "transport.gesture") throw new Error("not in this test");
      return new Promise((resolve) => (answer = resolve));
    });
    const before = prompts.length;
    const sending = pane.send("just text").catch(() => undefined);
    await Promise.resolve();
    pane.leave();
    answer({ ticket: "k-late" });
    await sending;
    expect(prompts.length).toBe(before + 1);
    expect(prompts.at(-1)).toMatchObject({ sessionId, meta: expect.objectContaining({ cmuxGesture: "k-late" }) });
  } finally {
    pane.close?.();
  }
});
