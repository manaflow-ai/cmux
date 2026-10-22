// The shared failure line's Retry (failedPromptGroups.ts) sends a run of failed prompts again as one
// prompt. The host counts one gesture per click of the person's and spends one on every
// `session/prompt` (AgentPaneUserGestures), so one click that sent each prompt of the run on its own
// got only the first through: the rest came back `transport.gesture_required` (review of #23898).
// None of them reached the agent, so one prompt with their texts in order (what Edit puts in the
// composer) and their attachments in order is the same ask. Edit takes the run back the same way.
// A run takes only its leading prompts whose attachments fit in one prompt (MAX_ATTACHMENTS); the rest
// stay failed rows for the next click, so no attachment is ever dropped. Prompts acpmux never answered
// may have been taken, so they are never joined: each goes again under its own id with `resend`.
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

type Row = {
  id: string;
  kind: string;
  text?: string;
  failed?: boolean;
  delivery?: { promptId: string; code?: string };
};
type Block = { type: string; text?: string; uri?: string };
type Sent = { prompt: Block[]; _meta: { acpmux: { promptId: string; resend?: boolean } } };

/// Yields until `done()` holds; fails after 2 s.
const settle = async (done: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

/// The mock daemon behind the host relay, which answers the `n`th `session/prompt` (from 1) as
/// `answer(n)` says: refused as the host refuses a send with no gesture left, never answered, or taken.
async function paneAnswering(answer: (n: number) => "refuse" | "silent" | "take") {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { translate } = await import("./i18n");
  const sent: Sent[] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const original = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return original(method, params);
        sent.push(params as Sent);
        const how = answer(sent.length);
        if (how === "take") return original(method, params);
        if (how === "silent") return new Promise(() => undefined);
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
  return {
    client,
    sent,
    get prompts() {
      return sent.map((each) => each.prompt);
    },
    rows: () => rows,
    failed: () => rows.filter((row) => row.kind === "user" && row.failed),
  };
}

/// The mock daemon that refuses the first `refused` prompts and takes the rest.
const paneRefusing = (refused: number) => paneAnswering((n) => (n > refused ? "take" : "refuse"));

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
  return Object.assign(pane, { rowIds: failed.map((row) => row.id) });
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

test("prompts acpmux never answered are not joined: Retry sends one again under its own id, with resend", async () => {
  // acpmux may have taken a prompt it did not answer in time (a slow link): a new prompt id would run
  // it a second time, so each goes again on its own, as acpmux knows it (failedPromptGroups.ts).
  const { deliveryTiming } = await import("./direct");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20, failMs: 80 });
  const silent = await paneAnswering(() => "silent");
  try {
    for (const [index, text] of texts.entries()) {
      void silent.client.send(text).catch(() => undefined);
      await settle(() => silent.sent.length === index + 1);
    }
    await settle(() => silent.failed().length === 3);
    const failed = silent.failed();
    expect(failed.map((row) => row.delivery?.code)).toEqual(["timeout", "timeout", "timeout"]);
    // No shared line offers it, and asked to anyway the client sends only the first, as itself.
    void silent.client.retryPrompts(failed.map((row) => row.id)).catch(() => undefined);
    await settle(() => silent.sent.length === 4);
    // A second send would go in the same task chain: yield to it a few times before counting.
    for (let turn = 0; turn < 5; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
    expect(silent.sent).toHaveLength(4);
    expect(silent.sent[3]!._meta.acpmux).toMatchObject({ promptId: failed[0]!.delivery!.promptId, resend: true });
    expect(silent.sent[3]!.prompt.find((block) => block.type === "text")?.text).toBe("p1");
    // The other two stay as they were, each for its own Retry.
    expect(silent.failed().map((row) => row.id)).toEqual(failed.slice(1).map((row) => row.id));
  } finally {
    Object.assign(deliveryTiming, timing);
    silent.client.close?.();
  }
});

const links = (prefix: string, count: number) =>
  Array.from({ length: count }, (_, index) => link(`${prefix}-${index + 1}`));
const uris = (blocks: Block[]) => blocks.filter((block) => block.type === "resource_link").map((block) => block.uri);
const fileUris = (prefix: string, count: number) =>
  links(prefix, count).map((attachment) => `file://${attachment.path}`);
const five = ["q1", "q2", "q3", "q4", "q5"];

/// Five prompts of three attachments each refused one after another: fifteen, more than one prompt holds.
async function fiveFailed() {
  const { MAX_ATTACHMENTS } = await import("./attachments");
  expect(3 * 3 <= MAX_ATTACHMENTS && MAX_ATTACHMENTS < 4 * 3).toBe(true);
  const refusing = await paneRefusing(5);
  for (const text of five) await refusing.client.send(text, links(text, 3)).catch(() => undefined);
  const rowIds = refusing.failed().map((row) => row.id);
  expect(refusing.failed().map((row) => row.text)).toEqual(five);
  return Object.assign(refusing, { rowIds });
}

test("Retry takes only the leading prompts whose attachments fit in one prompt; the rest stay for the next click", async () => {
  const run = await fiveFailed();
  try {
    await run.client.retryPrompts(run.rowIds);
    expect(run.sent).toHaveLength(6);
    expect(run.prompts[5]!.find((block) => block.type === "text")?.text).toBe("q1\n\nq2\n\nq3");
    expect(uris(run.prompts[5]!)).toEqual([...fileUris("q1", 3), ...fileUris("q2", 3), ...fileUris("q3", 3)]);
    // No attachment is dropped: the prompts that did not fit are still failed rows, as they were.
    expect(run.failed().map((row) => row.id)).toEqual(run.rowIds.slice(3));
    expect(run.failed().map((row) => row.text)).toEqual(["q4", "q5"]);
    await run.client.retryPrompts(run.failed().map((row) => row.id));
    expect(run.sent).toHaveLength(7);
    expect(run.prompts[6]!.find((block) => block.type === "text")?.text).toBe("q4\n\nq5");
    expect(uris(run.prompts[6]!)).toEqual([...fileUris("q4", 3), ...fileUris("q5", 3)]);
    expect(run.failed()).toHaveLength(0);
  } finally {
    run.client.close?.();
  }
});

test("Edit takes back only the leading prompts whose attachments fit in the composer", async () => {
  const run = await fiveFailed();
  try {
    expect(run.client.takeFailedPrompts(run.rowIds)).toEqual({
      input: "q1\n\nq2\n\nq3",
      attachments: [...links("q1", 3), ...links("q2", 3), ...links("q3", 3)],
    });
    expect(run.failed().map((row) => row.id)).toEqual(run.rowIds.slice(3));
  } finally {
    run.client.close?.();
  }
});

test("a run of prompts that were only attachments goes as one prompt of just those attachments", async () => {
  const refusing = await paneRefusing(2);
  try {
    const rowIds: string[] = [];
    for (const id of ["b1", "b2"])
      rowIds.push(
        await refusing.client.send("", [link(id)]).then(
          () => "",
          (error: { failedRow?: string }) => String(error.failedRow),
        ),
      );
    expect(rowIds.every((id) => id.startsWith("local-"))).toBe(true);
    await refusing.client.retryPrompts(rowIds);
    expect(refusing.sent).toHaveLength(3);
    expect(refusing.prompts[2]!.some((block) => block.type === "text")).toBe(false);
    expect(uris(refusing.prompts[2]!)).toEqual(["file:///tmp/b1.log", "file:///tmp/b2.log"]);
  } finally {
    refusing.client.close?.();
  }
});
