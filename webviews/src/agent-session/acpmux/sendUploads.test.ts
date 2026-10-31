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
  const two = [pdf(1, 8 * MIB), pdf(2, 9 * MIB)];
  expect(inlineBytes(promptBlocks("read these", two))).toBeGreaterThan(15 * MIB);
  expect(uploadsToFit("read these", two).map((chip) => chip.id)).toEqual(["pdf-2"]);
  // Under the budget nothing uploads.
  expect(uploadsToFit("read this", [pdf(1, 2 * MIB)])).toEqual([]);
});

test("a send's upload reserves the Send's ticket first and begins every file under it", async () => {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const call = async (method: string, params: Record<string, unknown>): Promise<unknown> => {
    calls.push({ method, params });
    if (method === "transport.gesture") return { ticket: "k-1" };
    if (method === "chat.upload.begin") return { token: "t", size: params.size, chunkSize: 512 * 1024 };
    if (method === "chat.upload.chunk")
      return { offset: (params.offset as number) + atob(params.data as string).length };
    if (method === "chat.upload.finish") return { path: "/Users/me/.cmux/uploads/Report 2.pdf" };
    return {};
  };
  const sent = await uploadForSend([pdf(2, 999)], { sessionId: "s-1", promptId: "p-1" }, call);
  expect(sent).toEqual({ ticket: "k-1", attachments: [expect.objectContaining({ kind: "link", saved: true })] });
  expect(calls[0]).toEqual({
    method: "transport.gesture",
    params: { intent: { method: "session/prompt", params: { promptId: "p-1", sessionId: "s-1" } } },
  });
  expect(calls[1]).toMatchObject({
    method: "chat.upload.begin",
    params: { name: "Report 2.pdf", size: 999, sessionId: "s-1", promptId: "p-1", ticket: "k-1" },
  });
  const link = (sent as { attachments: ComposerAttachment[] }).attachments[0]!;
  expect(link).toMatchObject({
    id: "pdf-2",
    path: "/Users/me/.cmux/uploads/Report 2.pdf",
    mimeType: "application/pdf",
    size: 999,
  });
});

test("a held prompt's ticket is reused; an upload that fails fails the send with its words", async () => {
  const methods: string[] = [];
  const failing = async (method: string): Promise<unknown> => {
    methods.push(method);
    if (method === "chat.upload.begin") throw new Error("The disk is full.");
    return {};
  };
  const sent = await uploadForSend([pdf(2, 1000)], { sessionId: "s-1", promptId: "p-1", ticket: "held" }, failing);
  expect(sent).toEqual({ error: "The disk is full." });
  expect(methods).not.toContain("transport.gesture");
});

// The client: two 9 MiB PDFs (12 MiB of base64 each) go in one message under the budget, as links.
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  scope.window = saved.window;
  scope.document = saved.document;
});

test("two 9 MiB PDFs go in one message under the budget: they upload at the Send and go as links", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const prompts: { prompt: PromptBlock[]; meta: Record<string, unknown> }[] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") prompts.push({ prompt: params.prompt, meta: params._meta });
        return answer(method, params);
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  const uploaded: string[] = [];
  client.uploadForSend = async (chips, prompt) => {
    uploaded.push(...chips.map((chip) => chip.name));
    expect(prompt.sessionId).toBeTruthy();
    return {
      ticket: "k-1",
      attachments: chips.map((chip) => ({
        ...chip,
        kind: "link" as const,
        data: undefined,
        path: `/up/${chip.name}`,
        saved: true,
      })),
    };
  };
  try {
    await client.send("read these", [pdf(1), pdf(2)]).catch(() => undefined);
    expect(uploaded.sort()).toEqual(["Report 1.pdf", "Report 2.pdf"]);
    const sent = prompts.at(-1)!;
    expect(inlineBytes(sent.prompt)).toBeLessThanOrEqual(PROMPT_INLINE_BUDGET);
    expect(sent.prompt.filter((block) => block.type === "document")).toHaveLength(0);
    for (const name of uploaded)
      expect(
        sent.prompt.some((block) => block.type === "resource_link" && block.uri.endsWith(encodeURIComponent(name))),
      ).toBe(true);
    // The prompt goes under the ticket its upload held.
    expect(sent.meta.cmuxGesture).toBe("k-1");
  } finally {
    client.close?.();
  }
});
