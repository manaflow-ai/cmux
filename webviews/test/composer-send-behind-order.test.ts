// l10n-allow-file: synthetic file names and host errors for a behavioral regression.
// A prompt sent while an earlier one still waits for its dropped file goes after it, never before
// (Leo, 2026-11-17: "JUST MAKE IT LOOK LIKE IT'S SENT OR JUST SEND IT"). Both show as sent at once; the
// later one reaches the agent only once the earlier one went, or failed for its file
// (composer/sendBehind.ts, direct.ts `send`). Before, a prompt with nothing attached went straight to
// the agent and overtook the one still waiting for its video. Ported from #53413 (sendBeforeFiles
// "a prompt sent after it goes after it") onto base's stand-in design.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ComposerAttachment, PromptBlock } from "../src/agent-session/acpmux/attachments";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
  });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const turn = () => new Promise((resolve) => setTimeout(resolve, 0));
type Row = { kind: string; text?: string; pending?: boolean; failed?: boolean };

/// A chat open on the mock daemon, its first prompt sent; `prompts` gets each prompt's words in the
/// order the agent got them.
async function openChat() {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const prompts: string[] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const original = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") {
          const blocks = params.prompt as PromptBlock[];
          prompts.push(blocks.flatMap((block) => (block.type === "text" ? [block.text] : [])).join(" "));
        }
        return original(method, params);
      };
    }
  }
  const view = { rows: [] as Row[] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (view.rows = snapshot.rows as Row[]),
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  client.setUnsentPromptStore({ read: async () => [], put: async () => undefined, remove: async () => undefined });
  await client.send("hello").catch(() => undefined);
  prompts.length = 0;
  return { client, prompts, view };
}

const clip = (id: string): ComposerAttachment => ({
  id,
  kind: "link",
  name: "clip.mov",
  mimeType: "video/quicktime",
  size: 3 * 1024 * 1024 * 1024,
});

test("a prompt sent while one before it waits for its file shows as sent at once and goes after it", async () => {
  const { sendBehind } = await import("../src/agent-session/acpmux/composer/sendBehind");
  const { client, prompts, view } = await openChat();
  try {
    let settle!: (value: { chip: ComposerAttachment }) => void;
    sendBehind("order-clip", new Promise((resolve) => (settle = resolve)));
    const first = client.send("first with the clip", [clip("order-clip")]);
    await turn();
    const pressed = performance.now();
    const second = client.send("second, nothing attached");
    await turn();
    expect(performance.now() - pressed).toBeLessThan(50);
    // Both show as sent while the clip still goes, and neither reached the agent yet.
    const shown = (words: string) => view.rows.some((row) => row.kind === "user" && row.text?.startsWith(words));
    expect(shown("first with the clip")).toBe(true);
    expect(shown("second, nothing attached")).toBe(true);
    for (let i = 0; i < 5; i += 1) await turn();
    expect(prompts).toEqual([]);
    settle({ chip: { ...clip("order-clip"), path: "/remote/clip.mov", saved: true } });
    await Promise.all([first.catch(() => undefined), second.catch(() => undefined)]);
    const deadline = Date.now() + 2_000;
    while (prompts.length < 2 && Date.now() < deadline) await turn();
    expect(prompts.map((words) => words.split(" ")[0])).toEqual(["first", "second,"]);
  } finally {
    client.close?.();
  }
});

test("a prompt sent behind one whose file failed still goes, after that one's row failed", async () => {
  const { sendBehind } = await import("../src/agent-session/acpmux/composer/sendBehind");
  const { client, prompts, view } = await openChat();
  try {
    let fail!: (value: { error: string }) => void;
    sendBehind("order-clip-2", new Promise((resolve) => (fail = resolve)));
    const first = client.send("first with the clip", [clip("order-clip-2")]);
    await turn();
    const second = client.send("second, nothing attached");
    for (let i = 0; i < 5; i += 1) await turn();
    expect(prompts).toEqual([]);
    fail({ error: "The disk is full." });
    await Promise.all([first.catch(() => undefined), second.catch(() => undefined)]);
    const deadline = Date.now() + 2_000;
    while (prompts.length < 1 && Date.now() < deadline) await turn();
    expect(prompts.map((words) => words.split(" ")[0])).toEqual(["second,"]);
    const failed = view.rows.find((row) => row.kind === "user" && row.text?.startsWith("first with the clip"));
    expect(failed?.failed).toBe(true);
  } finally {
    client.close?.();
  }
});

test("a prompt sent with nothing waiting before it goes at once, as before", async () => {
  const { client, prompts } = await openChat();
  try {
    await client.send("plain").catch(() => undefined);
    expect(prompts.map((words) => words.split(" ")[0])).toEqual(["plain"]);
  } finally {
    client.close?.();
  }
});
