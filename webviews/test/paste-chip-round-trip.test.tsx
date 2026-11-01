// l10n-allow-file: test fixture prompts, not shipped UI.
// A huge paste, end to end. The composer keeps a paste of more than 20 lines as a "Pasted text"
// chip and sends it as its own ACP text block after the typed one, marked `_meta.cmux.pasted`
// (#23396). acpmux records the prompt's text blocks joined with a newline as `user_message.text`
// and each marked block's UTF-16 range in it as `user_message.pasted` (hub/session.rs
// `prompt_text_parts`, #23407). The transcript draws each range as a "<first words> · N lines"
// chip (PromptText.tsx, #23431). This test runs the real composer, the real client and the real
// bubble, with acpmux's side done here exactly as session.rs does it, and checks that the bubble
// drawn at send (before acpmux answers) is the one drawn from acpmux's record: the same text,
// the same chips, in the same order, so nothing moves when the echo replaces it.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  inlineTokenIds,
  withoutInlineTokens,
  type ComposerAttachment,
  type PromptBlock,
} from "../src/agent-session/acpmux/attachments";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

const dom = new JSDOM("<!doctype html><div id=composer></div><div id=transcript></div>", {
  url: "https://cmux.test/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  NodeFilter: dom.window.NodeFilter,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  localStorage: dom.window.localStorage,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// jsdom lays nothing out and its Range has no rects; ProseMirror and the bubble's measure ask one.
const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
Object.assign(dom.window.Range.prototype, {
  getClientRects: () => Object.assign([box()], { item: () => box() }),
  getBoundingClientRect: box,
});

const { act, createRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("../src/agent-session/acpmux/Composer");
const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
const { noChat } = await import("../src/gallery/fixtures/acpmux");
const { translate } = await import("../src/agent-session/acpmux/i18n");

const CHAT = "0190a000-0000-7000-8000-0000000000f5";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
const composerHost = dom.window.document.getElementById("composer")!;
const transcriptHost = dom.window.document.getElementById("transcript")!;
let composerRoot: ReturnType<typeof createRoot> | undefined;
let transcriptRoot: ReturnType<typeof createRoot> | undefined;

afterEach(() => {
  act(() => composerRoot?.unmount());
  act(() => transcriptRoot?.unmount());
  composerRoot = transcriptRoot = undefined;
  composerHost.replaceChildren();
  transcriptHost.replaceChildren();
  // The composer keeps an unsent draft per chat in localStorage (composerDraft.ts).
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// A few macrotasks for React, the field and the client to finish what an event started.
const settle = () =>
  act(async () => {
    for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  });

/// Settles until `ready()` holds; fails after 3 s naming what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 3_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

// ---- The composer: a person types, pastes and presses Send. ----

type Sent = { text: string; attachments: ComposerAttachment[] };

async function compose(typed: string, pastes: string[]): Promise<Sent> {
  const sent: Sent[] = [];
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId: "chat-a",
    summary: { sessionId: "chat-a", harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
  });
  composerRoot ??= createRoot(composerHost);
  await act(async () =>
    composerRoot!.render(
      <Composer
        snapshot={snapshot}
        sessionId="chat-a"
        chips={() => null}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
  const field = () => composerHost.querySelector<HTMLElement>('[role="combobox"]');
  await until(() => !!field(), "the editor");
  if (typed)
    await act(async () => {
      const markdown = composerHost.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
      markdown.focus();
      markdown.insertTyped(typed);
    });
  // Each paste as WebKit delivers it: one ClipboardEvent with its text.
  for (const plain of pastes) {
    const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", {
      value: { files: [], types: ["text/plain"], getData: (type: string) => (type === "text/plain" ? plain : "") },
    });
    await act(async () => {
      field()!.dispatchEvent(event);
    });
    await settle();
  }
  await act(async () => {
    handle.current!.send();
  });
  expect(sent).toHaveLength(1);
  return sent[0]!;
}

// ---- acpmux: takes the prompt, records it as session.rs does, and echoes the record. ----

/// What acpmux records of a prompt's blocks (hub/session.rs `prompt_text_parts` and
/// `mark_pasted`): the text of every block with text, the context acpmux adds left out, joined
/// with a newline; and each block marked `_meta.cmux.pasted` as its range in that text, in UTF-16
/// code units (a JS string's own). No `pasted` key when nothing was pasted.
function recordOf(blocks: readonly Record<string, any>[]): { text: string; pasted?: { start: number; end: number }[] } {
  let text = "";
  const pasted: { start: number; end: number }[] = [];
  let index = 0;
  for (const block of blocks) {
    if (block._meta?.acpmux?.context === true) continue;
    if (typeof block.text !== "string") continue;
    if (index++ > 0) text += "\n";
    const start = text.length;
    text += block.text;
    if (block._meta?.cmux?.pasted === true) pasted.push({ start, end: text.length });
  }
  return pasted.length ? { text, pasted } : { text };
}

/// A daemon with one idle chat. It holds the pane's `session/prompt` (as acpmux does until the
/// turn ends) so the test can look at the pane before the echo, then sends the echo.
function fakeDaemon() {
  let socket: any;
  const held: { id: number; params: any }[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    steering: true,
    turnCount: 0,
    updatedAt: START,
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  };
  const deliver = (message: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", ...(message as object) }) });
  return {
    held,
    connect: () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id === undefined) return;
          if (message.method === "session/prompt") {
            held.push({ id: message.id, params: message.params });
            return;
          }
          queueMicrotask(() => deliver({ id: message.id, result: answer(message.method) }));
        },
        close() {},
      };
      queueMicrotask(() => socket.onopen?.());
      return socket as WebSocket;
    },
    /// Records the held prompt as acpmux does, sends that `user_message`, then answers the prompt.
    echo(seq: number) {
      const prompt = held.shift()!;
      const msg = {
        ...recordOf(prompt.params.prompt),
        promptId: prompt.params._meta.acpmux.promptId,
        turnId: "turn-1",
      };
      deliver({
        method: "_acpmux/event",
        params: { sessionId: CHAT, seq, at: START + seq * 1000, dir: "mux", kind: "user_message", msg },
      });
      deliver({ id: prompt.id, result: { stopReason: "end_turn" } });
      return msg;
    },
  };
}

// ---- The transcript: the prompt's bubble as App.tsx draws it. ----

/// What a reader sees of a bubble's text, in order: each typed part, and each paste chip by its
/// name, its line count and whether it is open; then the Show more toggle, if any.
function drawn(row: AcpmuxRow) {
  resetTranscriptDisclosure();
  transcriptRoot ??= createRoot(transcriptHost);
  act(() =>
    transcriptRoot!.render(
      <article data-row-id={row.id}>
        <UserBubble row={row} text={row.text ?? ""} />
      </article>,
    ),
  );
  const body = transcriptHost.querySelector(".cv-user__text")!;
  // A prompt whose attachments the composer placed draws in its recorded order, inside one inline
  // content run (InlinePromptContent.tsx): its parts are that run's.
  const run = body.querySelector(":scope > .cv-user__inline-content") ?? body;
  return {
    clamped: body.classList.contains("is-clamped"),
    parts: [...run.children].map((part): Record<string, string | null | undefined> =>
      part.classList.contains("cv-user__typed")
        ? { typed: part.textContent }
        : {
            name: part.querySelector(".cv-user__paste-name")?.textContent,
            lines: part.querySelector(".cv-user__paste-lines")?.textContent,
            open: part.querySelector(".cv-user__paste")?.getAttribute("aria-expanded"),
          },
    ),
    more: transcriptHost.querySelector(".cv-user__more")?.textContent ?? null,
  };
}

/// Sends what the composer gave through the real client to the fake acpmux, and returns the
/// prompt blocks sent, the bubble before the echo, and the bubble after it.
async function roundTrip(composed: Sent) {
  const daemon = fakeDaemon();
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.connect,
  );
  try {
    await settle();
    const users = () => rows.filter((row) => row.kind === "user");
    const sending = client.send(composed.text, composed.attachments, "p-paste");
    await until(() => daemon.held.length === 1 && users().length === 1, "the prompt on its way");
    const blocks = daemon.held[0]!.params.prompt as PromptBlock[];
    const pending = users()[0]!;
    expect(pending.pending).toBe(true);
    const before = drawn(pending);
    const record = daemon.echo(1);
    await sending;
    await until(() => users().length === 1 && users()[0]!.promptId === "p-paste", "acpmux's echo in the transcript");
    const echoed = users()[0]!;
    expect(echoed.pending).toBeFalsy();
    const after = drawn(echoed);
    return { blocks, record, pending, echoed, before, after };
  } finally {
    client.close();
  }
}

/// 2,300 lines of a build log: far over the composer's 20-line chip limit.
const LOG = Array.from({ length: 2300 }, (_, index) => `error at frame ${index + 1}: cannot resolve module`).join("\n");
/// A shorter paste, 25 lines, still a chip.
const TRACE = Array.from({ length: 25 }, (_, index) => `  at handler${index + 1} (server.ts:${index + 10})`).join("\n");
/// Typed text with a character of two UTF-16 units before the paste, so a range counted in code
/// points (or bytes) would land off by one.
const TYPED = "why does the build fail? 🧪";
const linesLabel = (n: number) => translate("transcript.pastedLines", { n, count: n.toLocaleString("en-US") });

test("a 2,300-line paste comes back as a Pasted chip after the typed text, drawn the same before and after acpmux's echo", async () => {
  const composed = await compose(TYPED, [LOG]);
  // The paste sits in the prompt where it went, after the typed text.
  expect(withoutInlineTokens(composed.text)).toBe(TYPED);
  expect(composed.text.startsWith(TYPED)).toBe(true);
  expect(composed.attachments.map((chip) => chip.kind)).toEqual(["pasted"]);
  expect(inlineTokenIds(composed.text)).toEqual(composed.attachments.map((chip) => chip.id));

  const { blocks, record, pending, echoed, before, after } = await roundTrip(composed);
  // The wire: the typed block, then the paste as its own block, marked.
  expect(blocks).toEqual([
    { type: "text", text: TYPED },
    { type: "text", text: LOG, _meta: { cmux: { pasted: true } } },
  ]);
  // acpmux's record: the paste's range starts after the typed text and its newline, in UTF-16 units.
  const start = TYPED.length + 1;
  expect(record.text).toBe(`${TYPED}\n${LOG}`);
  expect(record.pasted).toEqual([{ start, end: start + LOG.length }]);
  expect(record.text.slice(start, start + LOG.length)).toBe(LOG);

  // The bubble drawn at send already is the echo's: same text, same ranges.
  expect(pending.text).toBe(record.text);
  expect(pending.pasted).toEqual(record.pasted);
  expect(echoed.text).toBe(record.text);
  expect(echoed.pasted).toEqual(record.pasted);

  // What the reader sees: the typed words first, then one closed chip naming the paste.
  expect(after.parts).toHaveLength(2);
  expect(after.parts[0]!.typed?.trim()).toBe(TYPED);
  expect(after.parts[1]).toEqual({
    name: "error at frame 1: cannot resolve module",
    lines: linesLabel(2300),
    open: "false",
  });
  expect(transcriptHost.querySelector(".cv-user__text")!.textContent).not.toContain("error at frame 2300");
  // And nothing moves when the echo takes the pending bubble's place.
  expect(before).toEqual(after);
});

test("two pastes with nothing typed come back as two chips in the order they were pasted, before and after the echo", async () => {
  const composed = await compose("", [LOG, TRACE]);
  // Nothing typed: the prompt is the two pastes, in the order they went in.
  expect(withoutInlineTokens(composed.text)).toBe("");
  expect(composed.attachments.map((chip) => chip.kind)).toEqual(["pasted", "pasted"]);
  expect(inlineTokenIds(composed.text)).toEqual(composed.attachments.map((chip) => chip.id));

  const { blocks, record, pending, before, after } = await roundTrip(composed);
  expect(blocks).toEqual([
    { type: "text", text: LOG, _meta: { cmux: { pasted: true } } },
    { type: "text", text: TRACE, _meta: { cmux: { pasted: true } } },
  ]);
  expect(record.text).toBe(`${LOG}\n${TRACE}`);
  expect(record.pasted).toEqual([
    { start: 0, end: LOG.length },
    { start: LOG.length + 1, end: LOG.length + 1 + TRACE.length },
  ]);
  expect(pending.text).toBe(record.text);
  expect(pending.pasted).toEqual(record.pasted);

  // Between the two chips is the newline that joined them, which draws nothing.
  const chips = after.parts.filter((part) => !("typed" in part) || part.typed?.trim());
  expect(chips).toEqual([
    { name: "error at frame 1: cannot resolve module", lines: linesLabel(2300), open: "false" },
    { name: "at handler1 (server.ts:10)", lines: linesLabel(25), open: "false" },
  ]);
  expect(before).toEqual(after);
});
