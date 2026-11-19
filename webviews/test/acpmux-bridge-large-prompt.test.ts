// Leo, 2026-11-17: two 1:12 screen recordings dragged from Finder into a chat on this Mac, with 801
// characters of text, failed after five minutes: "Not sent: no answer from cmux" (hop acpmux, code
// timeout, 301641 ms). Leo: "STOP *** BLOCKING ON SOME RANDOM *** WHAT THE *** COULD TAKE SO LONG
// ABOUT LINKING A *** VIDEO / I DRAG AND DROP IT IN WTF ARE YOU *** ENCODING".
//
// acpmux never saw the prompt. A video goes as its link plus its key frames as JPEGs
// (composer/videoPrompt.ts), up to 4 MiB of base64 a video (videoFramePick.ts FRAME_BYTES), and the
// prompt's budget was acpmux's 28 MiB (promptBudget.ts). The pane's socket is the app's bridge
// (bridgeSocket.ts): each frame goes in a `transport.send` page call, and the Chromium page host
// takes no call over 4 MiB (ChromiumPageHostBridge.maximumPayloadBytes): it answers such a call
// `cmux.protocol.too_large`, which reached bridgeSocket as an error with no code, and bridgeSocket
// let it go. So the `session/prompt` frame was never sent and never answered, and the row waited
// for the pane's 300 s deadline (direct.ts `localFailMs`).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ComposerAttachment, PromptBlock } from "../src/agent-session/acpmux/attachments";
import { BridgeSocket, receiveTransportEvent } from "../src/agent-session/acpmux/bridgeSocket";
import { NativeError } from "../src/agent-session/acpmux/nativeError";
import { settleReact } from "./support/domTeardown";

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
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

/// ChromiumPageHostBridge.maximumPayloadBytes, literal so the test reads the same on a base without
/// the page's copy of it.
const PAGE_HOST_CALL_BYTES = 4 << 20;
const MIB = 1024 * 1024;

const utf8 = (text: string) => new TextEncoder().encode(text).length;

/// The page host's binding payload for one `cmux.agent.*` call (ChromiumPageHostBridge.pageScript).
const callBytes = (method: string, params: unknown) =>
  utf8(JSON.stringify({ name: "cmuxPage", seq: 1, body: { op: `cmux.agent.${method}`, id: "x", params } }));

/// The app's host as the Chromium page host has it: a call over 4 MiB is refused before it leaves the
/// page, as `callPageHost` rejects it (a NativeError with no code); every other frame goes to `daemon`.
function chromiumHost(daemon: () => { send(raw: string): void; onmessage: ((m: { data: string }) => void) | null }) {
  const calls: { method: string; bytes: number; frames?: string[] }[] = [];
  let connection = 0;
  let socket: ReturnType<typeof daemon> | undefined;
  const post = async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
    const bytes = callBytes(method, params);
    calls.push({ method, bytes, frames: params.frames as string[] | undefined });
    if (bytes > PAGE_HOST_CALL_BYTES) throw new NativeError({ userMessage: "The request is too large to send." });
    if (method === "transport.open") {
      connection += 1;
      const id = connection;
      socket = daemon();
      socket.onmessage = (message) => receiveTransportEvent({ connection: id, frames: [message.data] });
      return { connection: id } as T;
    }
    if (method === "transport.send") for (const frame of params.frames as string[]) socket?.send(frame);
    return null as T;
  };
  return { calls, post };
}

const settle = async () => {
  for (let index = 0; index < 20; index++) await new Promise((resolve) => setTimeout(resolve, 0));
};

test("a frame too large for the page host is answered at once, and the frames beside it still go", async () => {
  const daemonGot: string[] = [];
  const host = chromiumHost(() => ({ send: (raw) => daemonGot.push(raw), onmessage: null }));
  const socket = new BridgeSocket(host.post);
  const answers: Record<string, unknown>[] = [];
  socket.onmessage = (message) => answers.push(JSON.parse(message.data));
  await settle();
  expect(socket.readyState).toBe(BridgeSocket.OPEN);
  const small = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "_acpmux/watch", params: {} });
  const large = JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "session/prompt",
    params: { sessionId: "s", prompt: [{ type: "image", mimeType: "image/jpeg", data: "A".repeat(5 * MIB) }] },
  });
  // One task writes both, as a send with a read beside it does: they would go in one call.
  socket.send(small);
  socket.send(large);
  await settle();
  // The small frame reached acpmux; the large one never left the page.
  expect(daemonGot).toEqual([small]);
  expect(host.calls.every((call) => call.bytes <= PAGE_HOST_CALL_BYTES || !call.frames?.includes(small))).toBe(true);
  // The large request has its answer now, not after the pane's 300 s deadline: acpmux's own refusal
  // of a message too large (rpc.rs `too_large`), which the pane already reads (sendFailure.ts).
  const refusal = answers.find((answer) => answer.id === 2) as { error?: { data?: { reason?: string } } } | undefined;
  expect(refusal?.error?.data?.reason).toBe("message.too_large");
  socket.close();
});

/// A screen recording's chip as the composer has it once the host read its frames: its link and 16
/// frames of about 260 KB of base64 each, near its own 4 MiB cap (videoFramePick.ts FRAME_BYTES).
function recording(index: number): ComposerAttachment {
  const frames = Array.from({ length: 16 }, (_, at) => ({ atMs: at * 4_500, data: "A".repeat(260_000) }));
  return {
    id: `link:/Users/me/Movies/Screen Recording ${index}.mov`,
    kind: "link",
    name: `Screen Recording ${index}.mov`,
    mimeType: "",
    size: 400 * MIB,
    path: `/Users/me/Movies/Screen Recording ${index}.mov`,
    video: { durationMs: 72_000, width: 2560, height: 1600, poster: "data:image/jpeg;base64,AA==", frames },
  };
}

test("two screen recordings and 801 characters reach acpmux over the app's bridge, with frames of each", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const prompts: PromptBlock[][] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") prompts.push(params.prompt as PromptBlock[]);
        return answer(method, params);
      };
    }
  }
  const host = chromiumHost(() => new Relay() as never);
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => new BridgeSocket(host.post) as unknown as WebSocket,
  );
  try {
    const started = Date.now();
    let outcome: string | undefined;
    const sent = client.send("x".repeat(801), [recording(1), recording(2)]).then(
      () => (outcome = "sent"),
      (error: unknown) => (outcome = `failed: ${String((error as Error)?.message ?? error)}`),
    );
    for (let step = 0; step < 200 && !prompts.length && !outcome; step++) await settle();
    // acpmux has the prompt, in well under a second: no page call past the page host's limit.
    expect(prompts).toHaveLength(1);
    expect(Date.now() - started).toBeLessThan(5_000);
    expect(host.calls.every((call) => call.bytes <= PAGE_HOST_CALL_BYTES)).toBe(true);
    const blocks = prompts[0]!;
    // Both videos go as their links, and each keeps frames for the agent to look at.
    const links = blocks.filter((block) => block.type === "resource_link");
    expect(links.map((block) => (block as { name: string }).name)).toEqual([
      "Screen Recording 1.mov",
      "Screen Recording 2.mov",
    ]);
    for (const video of ["Screen Recording 1.mov", "Screen Recording 2.mov"]) {
      const frames = blocks.filter(
        (block) => block.type === "image" && (block as { name?: string }).name?.startsWith(`${video} frame at`),
      );
      expect(frames.length).toBeGreaterThan(0);
    }
    void sent;
  } finally {
    client.close?.();
  }
});
