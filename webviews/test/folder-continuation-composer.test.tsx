// l10n-allow-file: regression fixture text.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
const dom = new JSDOM("<!doctype html><div id=composer></div>", {
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
const { noChat } = await import("../src/gallery/fixtures/acpmux");
const { readPersistedDraft } = await import("../src/agent-session/acpmux/composerDraft");
const host = document.getElementById("composer")!;
let root: ReturnType<typeof createRoot>;
afterEach(() => {
  act(() => root.unmount());
  dom.window.localStorage.clear();
});
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
const attachment: ComposerAttachment = {
  id: "file-one",
  kind: "text",
  name: "note.txt",
  mimeType: "text/plain",
  size: 16,
  text: "attached content",
};
async function fixture(options: { refuse?: boolean; delay?: Promise<void> } = {}) {
  root = createRoot(host);
  const handle = createRef<ComposerHandle>();
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const writes: { id: string; chips: ComposerAttachment[] }[] = [];
  let finishRead!: (chips: ComposerAttachment[]) => void;
  const store = {
    read: (id: string): Promise<ComposerAttachment[]> =>
      id === "destination"
        ? new Promise((resolve) => {
            finishRead = resolve;
          })
        : Promise.resolve([]),
    write: async (id: string, chips: ComposerAttachment[]) => {
      writes.push({ id, chips });
      if (id === "destination") await options.delay;
      return { held: options.refuse && id === "destination" ? [] : chips.map((c) => c.id) };
    },
  };
  const draw = (id: string) =>
    act(async () =>
      root.render(
        <Composer
          sessionId={id}
          snapshot={noChat([], {
            sessionId: id,
            summary: { sessionId: id, harness: "claude", cwd: "/project", turnCount: 0 },
          })}
          chips={() => null}
          onSend={(text, attachments) => {
            sent.push({ text, attachments: attachments ?? [] });
            return true;
          }}
          onStop={() => {}}
          handle={handle}
          keptAttachments={store}
        />,
      ),
    );
  await draw("source");
  await act(async () => {
    handle.current!.restore("held draft", [attachment]);
  });
  return { handle, draw, sent, writes, finishRead: () => act(async () => finishRead([])) };
}
test("text and attachment arrive once despite a delayed empty destination read", async () => {
  const f = await fixture();
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  await transfer.ready;
  await f.draw("destination");
  await act(async () => transfer.commit());
  await f.finishRead();
  expect(f.handle.current!.draftState()).toEqual({ text: "held draft", attachments: [attachment] });
  expect(readPersistedDraft("source") ?? "").toBe("");
  expect(f.writes.some((w) => w.id === "source" && w.chips.length === 0)).toBe(true);
  expect(f.sent).toHaveLength(0);
  await act(async () => {
    f.handle.current!.send();
  });
  await act(async () => {
    f.handle.current!.send();
  });
  expect(f.sent).toEqual([{ text: "held draft", attachments: [attachment] }]);
  await f.draw("other");
  expect(f.handle.current!.draftState()).toEqual({ text: "", attachments: [] });
});
test("a cancelled transfer preserves the source without restore or duplication", async () => {
  const f = await fixture();
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  await transfer.ready;
  act(() => transfer.cancel());
  expect(f.handle.current!.draftState()).toEqual({ text: "held draft", attachments: [attachment] });
  await f.draw("other");
  expect(f.handle.current!.draftState()).toEqual({ text: "", attachments: [] });
  expect(readPersistedDraft("source")).toBe("held draft");
  expect(f.sent).toHaveLength(0);
});
test("a different selected session never receives a pending transfer", async () => {
  let resolve!: () => void;
  const f = await fixture({
    delay: new Promise<void>((yes) => {
      resolve = yes;
    }),
  });
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  const outcome = transfer.ready.catch((error) => error);
  await f.draw("other");
  resolve();
  expect((await outcome).message).toBe("draft changed during recovery");
  transfer.cancel();
  expect(f.handle.current!.draftState()).toEqual({ text: "", attachments: [] });
  expect(readPersistedDraft("source")).toBe("held draft");
});

test("failed selection after rendering preserves the source, while destination chips are durable", async () => {
  const f = await fixture();
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  await transfer.ready;
  await f.draw("destination");
  await f.draw("other");
  act(() => transfer.cancel());
  expect(readPersistedDraft("source")).toBe("held draft");
  expect(f.writes.some((w) => w.id === "destination" && w.chips[0]?.id === attachment.id)).toBe(true);
  expect(f.writes.some((w) => w.id === "source" && w.chips.length === 0)).toBe(false);
  expect(f.sent).toHaveLength(0);
});

test("a destination store that retains no contents leaves the source intact", async () => {
  const f = await fixture({ refuse: true });
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  await expect(transfer.ready).rejects.toThrow("draft contents were not retained");
  transfer.cancel();
  expect(f.handle.current!.draftState()).toEqual({ text: "held draft", attachments: [attachment] });
  expect(f.writes.some((w) => w.id === "source" && w.chips.length === 0)).toBe(false);
});
test("edits while the destination save waits abort recovery and preserve the newer draft", async () => {
  let resolve!: () => void;
  const f = await fixture({
    delay: new Promise<void>((yes) => {
      resolve = yes;
    }),
  });
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  await act(async () => f.handle.current!.prefill("new edit "));
  resolve();
  await expect(transfer.ready).rejects.toThrow("draft changed during recovery");
  transfer.cancel();
  expect(f.handle.current!.draftState().text).toBe("new edit held draft");
  expect(f.sent).toHaveLength(0);
});

test("commit before destination render keeps edits made during selection in the source", async () => {
  const f = await fixture();
  const transfer = f.handle.current!.prepareDraftTransfer("destination");
  await transfer.ready;
  await act(async () => f.handle.current!.prefill("edited "));
  act(() => transfer.commit());
  await f.draw("destination");
  await f.finishRead();
  expect(readPersistedDraft("source")).toBe("edited held draft");
  expect(f.handle.current!.draftState().text).toBe("held draft");
  expect(f.writes.some((w) => w.id === "source" && w.chips.length === 0)).toBe(false);
});
