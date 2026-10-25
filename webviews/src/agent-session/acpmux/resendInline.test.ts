// A prompt with attachments placed in its text goes again in its order: Retry, Retry With and Edit
// and Resend (App.tsx) send it through `resendPrompt` (direct.ts), which keeps each mark among its
// words, edited or not, and for a prompt this page did not send reads the order from the row's
// ordered parts. Before, they sent the row's words and its attachments, so the agent got the images
// after the text (composer-opus's review of #24724).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { INLINE_ATTACHMENT_MARK as MARK, type ComposerAttachment } from "./attachments";
import type { AcpmuxRow } from "./model";
import { carryMarks } from "./resendInline";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

const settle = async (done: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown>; emit: (target: string, step: any) => void };

async function connect(echoBeforeReply = true) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const sent: any[] = [];
  /// The next prompt sent from here on.
  const next = async (send: () => Promise<unknown>) => {
    const from = sent.length;
    await send();
    await settle(() => sent.length > from);
    return sent[sent.length - 1];
  };
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
          // acpmux echoes a prompt (its user_message) before the turn's answer.
          if (echoBeforeReply && params.prompt.some((block: { type: string }) => block.type === "image"))
            emit!(params.sessionId, {
              mux: "user_message",
              msg: {
                promptId: params._meta?.acpmux?.promptId,
                text: params.prompt
                  .filter((block: { type: string }) => block.type === "text")
                  .map((block: { text: string }) => block.text)
                  .join("\n"),
              },
            });
          return { stopReason: "end_turn" };
        }
        if (method === "_acpmux/attachment") return { mimeType: "image/png", data: `bytes-of-${params.id}` };
        return answer(method, params);
      };
    }
  }
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows),
    undefined,
    () => new Host() as unknown as WebSocket,
  );
  return { client, sent, next, emit: (target: string, step: any) => emit!(target, step), rows: () => rows };
}

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 3,
  data: "AQID",
  inline: true,
});
const shape = (prompt: { type: string; text?: string; name?: string }[]) =>
  prompt.map((block) => (block.type === "text" ? block.text : `[${block.type}]`));

test("carryMarks keeps each mark among the words, edited or not", () => {
  expect(carryMarks(`look ${MARK} and ${MARK} ok`, "look  and  ok")).toBe(`look ${MARK} and ${MARK} ok`);
  // Words added where a mark is go after it; a mark after an edit moves with its words.
  expect(carryMarks(`look ${MARK} and ${MARK} ok`, "look here  and  ok")).toBe(`look ${MARK}here  and ${MARK} ok`);
  expect(carryMarks(`look ${MARK} and ${MARK} ok`, "see  and  ok")).toBe(`see ${MARK} and ${MARK} ok`);
  // Marks at the edges of words that changed stay at the edges of the new words.
  expect(carryMarks(`a${MARK}b${MARK}c`, "aXYZc")).toBe(`a${MARK}XYZ${MARK}c`);
  // The shown text joins the runs with a line: the marks stay at the runs' edges.
  expect(carryMarks(`${MARK}caption one${MARK}caption two`, "caption one\ncaption two")).toBe(
    `${MARK}caption one${MARK}\ncaption two`,
  );
  expect(carryMarks("no marks", "edited")).toBe("edited");
});

test("Retry and Edit and Resend send a prompt this page sent in its order", async () => {
  const { client, next, emit, rows } = await connect();
  try {
    await next(() => client.send(`${MARK}caption one${MARK}caption two`, [image("one"), image("two")]));
    await settle(() => rows().some((row) => row.id.startsWith("user-") && Boolean(row.text?.includes("caption one"))));
    const row = rows().find((each) => each.id.startsWith("user-") && each.text?.includes("caption one"))!;
    // Retry: the row's words as shown.
    const again = await client.resendPrompt(row.id, row.text ?? "caption one\ncaption two");
    expect(shape((await next(() => client.send(again.input, again.attachments))).prompt)).toEqual([
      "[image]",
      "caption one",
      "[image]",
      "caption two",
    ]);
    // Edit and Resend: edited words, the images where they were.
    const edited = await client.resendPrompt(row.id, "caption 1\ncaption two");
    expect(shape((await next(() => client.send(edited.input, edited.attachments))).prompt)).toEqual([
      "[image]",
      "caption 1\n",
      "[image]",
      "caption two",
    ]);
  } finally {
    client.close?.();
  }
});

test("a prompt read back from acpmux (sent before a reload) goes again in its recorded order", async () => {
  const { client, next, emit, rows } = await connect();
  try {
    const warm = await next(() => client.send("warm up", []));
    emit(warm.sessionId, {
      mux: "user_message",
      msg: {
        text: "before\nafter",
        images: [
          { id: "sha-a", mimeType: "image/png" },
          { id: "sha-b", mimeType: "image/png" },
        ],
        inlineParts: [
          { kind: "text", text: "before" },
          { kind: "image", id: "sha-a", mimeType: "image/png" },
          { kind: "text", text: "after" },
          { kind: "image", id: "sha-b", mimeType: "image/png" },
        ],
      },
    });
    await settle(() => rows().some((row) => row.inlineParts?.some((part) => part.kind === "image")));
    const row = rows().find((each) => each.inlineParts?.some((part) => part.kind === "image"))!;
    const again = await client.resendPrompt(row.id, "before\nafter");
    const last = (await next(() => client.send(again.input, again.attachments))).prompt as {
      type: string;
      text?: string;
      data?: string;
    }[];
    expect(shape(last)).toEqual(["before", "[image]", "\nafter", "[image]"]);
    expect(last.filter((block) => block.type === "image").map((block) => block.data)).toEqual([
      "bytes-of-sha-a",
      "bytes-of-sha-b",
    ]);
  } finally {
    client.close?.();
  }
});

test("Retry keeps an inline paste exactly once, between the same text and image blocks", async () => {
  const { client, next, rows } = await connect();
  const paste: ComposerAttachment = {
    id: "paste",
    kind: "pasted",
    name: "Pasted text",
    mimeType: "text/plain",
    size: 11,
    text: "pasted body",
    inline: true,
  };
  try {
    const first = await next(() => client.send(`before${MARK}between${MARK}after`, [paste, image("shot")]));
    await settle(() => rows().some((row) => row.id.startsWith("user-") && row.text?.includes("pasted body")));
    const row = rows().find((row) => row.id.startsWith("user-") && row.text?.includes("pasted body"))!;
    const again = await client.resendPrompt(row.id, row.text!);
    const second = await next(() => client.send(again.input, again.attachments));
    expect(second.prompt).toEqual(first.prompt);
    const edited = await client.resendPrompt(row.id, row.text!.replace("before", "edited"));
    const changed = await next(() => client.send(edited.input, edited.attachments));
    const words = changed.prompt
      .filter((part: { type: string }) => part.type === "text")
      .map((part: { text: string }) => part.text)
      .join("");
    expect(words.match(/pasted body/g)).toHaveLength(1);
    expect(words).toContain("edited");
    expect(changed.prompt.filter((part: { type: string }) => part.type === "image")).toHaveLength(1);
  } finally {
    client.close?.();
  }
});

test("a prompt reply before its durable echo keeps the ordered paste for Retry", async () => {
  const { client, next, emit, rows } = await connect(false);
  const paste: ComposerAttachment = {
    id: "paste",
    kind: "pasted",
    name: "Pasted text",
    mimeType: "text/plain",
    size: 11,
    text: "pasted body",
    inline: true,
  };
  try {
    const first = await next(() => client.send(`before${MARK}between${MARK}after`, [paste, image("shot")]));
    const text = first.prompt
      .filter((part: { type: string }) => part.type === "text")
      .map((part: { text: string }) => part.text)
      .join("\n");
    emit(first.sessionId, { mux: "user_message", msg: { promptId: first._meta.acpmux.promptId, text } });
    await settle(() => rows().some((row) => row.id.startsWith("user-") && row.text === text));
    const row = rows().find((row) => row.id.startsWith("user-") && row.text === text)!;
    const again = await client.resendPrompt(row.id, text);
    expect((await next(() => client.send(again.input, again.attachments))).prompt).toEqual(first.prompt);
  } finally {
    client.close?.();
  }
});
