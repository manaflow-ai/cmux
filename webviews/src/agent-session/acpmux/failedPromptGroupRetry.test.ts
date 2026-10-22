// The shared failure line's Retry (failedPromptGroups.ts) sends a run of failed prompts again as one
// prompt. The host counts one gesture per click of the person's and spends one on every
// `session/prompt` (AgentPaneUserGestures), so one click that sent each prompt of the run on its own
// got only the first through: the rest came back `transport.gesture_required` (review of #23898).
// None of them reached the agent, so one prompt with their texts in order (what Edit puts in the
// composer) and their attachments in order is the same ask. Edit takes the run back the same way.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ComposerAttachment } from "./attachments";

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

type Row = { id: string; kind: string; text?: string; failed?: boolean };
type Block = { type: string; text?: string; uri?: string };

/// The mock daemon behind the host relay, which refuses the first `refused` prompts as the host does
/// a send with no gesture left.
async function paneRefusing(refused: number) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { translate } = await import("./i18n");
  const prompts: Block[][] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        prompts.push(params.prompt as Block[]);
        if (prompts.length > refused) return answer(method, params);
        return Promise.reject(
          Object.assign(new Error(translate("transport.gestureRequired")), { code: "transport.gesture_required" }),
        );
      };
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  return { client, prompts, rows: () => rows };
}

const link = (id: string): ComposerAttachment => ({
  id,
  kind: "link",
  name: `${id}.log`,
  mimeType: "text/plain",
  size: 1,
  path: `/tmp/${id}.log`,
});
const texts = ["p1", "p2", "p3"];

/// Three prompts refused one after another, and their failed rows in the order they were sent.
async function threeFailed() {
  const pane = await paneRefusing(3);
  for (const [index, text] of texts.entries())
    await pane.client.send(text, [link(`a${index + 1}`)]).catch(() => undefined);
  const failed = pane.rows().filter((row) => row.kind === "user" && row.failed);
  expect(failed.map((row) => row.text)).toEqual(texts);
  return { ...pane, rowIds: failed.map((row) => row.id) };
}

test("the shared line's Retry sends the run as one prompt, its texts and attachments in order", async () => {
  const pane = await threeFailed();
  try {
    await pane.client.retryPrompts(pane.rowIds);
    // One click, one prompt: three refused sends and the one Retry.
    expect(pane.prompts).toHaveLength(4);
    const sent = pane.prompts.at(-1)!;
    expect(sent.find((block) => block.type === "text")?.text).toBe("p1\n\np2\n\np3");
    expect(sent.filter((block) => block.type === "resource_link").map((block) => block.uri)).toEqual([
      "file:///tmp/a1.log",
      "file:///tmp/a2.log",
      "file:///tmp/a3.log",
    ]);
    // The three failed rows are gone; the prompt that went has one bubble, not failed.
    const users = pane.rows().filter((row) => row.kind === "user");
    expect(users.some((row) => row.failed)).toBe(false);
    for (const id of pane.rowIds) expect(users.some((row) => row.id === id)).toBe(false);
    expect(users.filter((row) => row.text === "p1\n\np2\n\np3")).toHaveLength(1);
  } finally {
    pane.client.close?.();
  }
});

test("Edit on the shared line takes the run back as one prompt, in order", async () => {
  const pane = await threeFailed();
  try {
    expect(pane.client.takeFailedPrompts(pane.rowIds)).toEqual({
      input: "p1\n\np2\n\np3",
      attachments: [link("a1"), link("a2"), link("a3")],
    });
    expect(pane.rows().some((row) => row.kind === "user" && row.failed)).toBe(false);
  } finally {
    pane.client.close?.();
  }
});
