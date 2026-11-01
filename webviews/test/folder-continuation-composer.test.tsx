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
const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
const { noChat } = await import("../src/gallery/fixtures/acpmux");
const { readPersistedDraft, writePersistedDraft } = await import("../src/agent-session/acpmux/composerDraft");
const host = document.getElementById("composer")!;
let root: ReturnType<typeof createRoot>;
// acpmux's draft store: a chat hydrates only once its read answers (composerDraft.ts
// readDurableDraftState), so the fixture answers it as acpmux does, from what was written.
const daemonDrafts = new Map<string, string>();
const page = dom.window as unknown as { cmuxAcpmuxActions?: Record<string, (params: unknown) => Promise<unknown>> };
page.cmuxAcpmuxActions = {
  "chat.readDraft": async (params) => ({
    draft: daemonDrafts.get(String((params as { sessionId: string }).sessionId)),
  }),
  "chat.writeDraft": async (params) => {
    const { sessionId, text } = params as { sessionId: string; text: string };
    if (text.trim()) daemonDrafts.set(sessionId, text);
    else daemonDrafts.delete(sessionId);
  },
};
afterEach(() => {
  act(() => root.unmount());
  dom.window.localStorage.clear();
  daemonDrafts.clear();
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
async function fixture() {
  setComposerSettings({ attachmentView: "inline" });
  root = createRoot(host);
  const handle = createRef<ComposerHandle>();
  const sent: string[] = [];
  const stored = new Map<string, ComposerAttachment[]>();
  const store = {
    read: async (id: string) => stored.get(id) ?? [],
    write: async (id: string, chips: ComposerAttachment[]) => {
      stored.set(id, chips);
      return { held: chips.map((c) => c.id) };
    },
  };
  const draw = (id: string | undefined) =>
    act(async () =>
      root.render(
        <Composer
          sessionId={id}
          snapshot={noChat([], {
            sessionId: id,
            ...(id ? { summary: { sessionId: id, harness: "claude", cwd: "/project", turnCount: 0 } } : {}),
          })}
          chips={() => null}
          onSend={(text) => {
            sent.push(text);
            return true;
          }}
          onStop={() => {}}
          handle={handle}
          keptAttachments={store}
        />,
      ),
    );
  await draw("source");
  await act(async () => handle.current!.restore("held draft", [attachment]));
  const sourceDraft = readPersistedDraft("source");
  const copy = () => writePersistedDraft("destination", handle.current!.draftText());
  return { handle, draw, sent, stored, copy, sourceDraft };
}
test("recovery copies only text, keeps the source intact, and sends nothing", async () => {
  const f = await fixture();
  f.copy();
  await f.draw("destination");
  expect(f.handle.current!.draftText()).toBe("held draft");
  expect(f.handle.current!.wakeState().attachments).toEqual([]);
  expect(f.stored.get("source")).toEqual([attachment]);
  expect(readPersistedDraft("source")).toBe(f.sourceDraft);
  expect(f.sent).toEqual([]);
  await f.draw("source");
  expect(f.handle.current!.draftText()).toBe("held draft");
  expect(f.handle.current!.wakeState().attachments).toEqual([attachment]);
});
test("text-only recovery suppresses normal attachment carry into the destination", async () => {
  const f = await fixture();
  f.handle.current!.suppressAttachmentCarryFor("source");
  await f.draw("destination");
  expect(f.stored.get("destination") ?? []).toEqual([]);
  expect(f.handle.current!.wakeState().attachments).toEqual([]);
  await f.draw("source");
  expect(f.stored.get("source")).toEqual([attachment]);
  expect(f.handle.current!.wakeState().attachments).toEqual([attachment]);
});
test("text-only recovery suppresses unbound attachment scopes from a fresh chat", async () => {
  const f = await fixture();
  await f.draw(undefined);
  await act(async () => f.handle.current!.restore("held draft", [attachment]));
  f.handle.current!.suppressAttachmentCarryFor(undefined);
  await f.draw("destination");
  expect(f.handle.current!.wakeState().attachments).toEqual([]);
});
test("failed selection leaves the source unchanged without restoring twice", async () => {
  const f = await fixture();
  const { FolderContinuation } = await import("../src/agent-session/acpmux/folderContinuation");
  await expect(
    new FolderContinuation().run({
      start: async () => "destination",
      current: () => true,
      copyText: f.copy,
      select: async () => {
        throw new Error("offline");
      },
      clearFolder: () => {
        throw new Error("must not clear");
      },
    }),
  ).rejects.toThrow("offline");
  expect(f.handle.current!.draftText()).toBe("held draft");
  expect(f.handle.current!.wakeState().attachments).toEqual([attachment]);
  expect(f.sent).toEqual([]);
});
test("edits while selecting remain in the source and another chat receives no copied text", async () => {
  const f = await fixture();
  const { FolderContinuation } = await import("../src/agent-session/acpmux/folderContinuation");
  let resolve!: (value: boolean) => void;
  let began!: () => void;
  const started = new Promise<void>((yes) => {
    began = yes;
  });
  const run = new FolderContinuation().run({
    start: async () => "destination",
    current: () => true,
    copyText: f.copy,
    select: () => {
      began();
      return new Promise<boolean>((yes) => {
        resolve = yes;
      });
    },
    clearFolder: () => {
      throw new Error("must not clear");
    },
  });
  await started;
  await act(async () => f.handle.current!.prefill("edited "));
  await f.draw("other");
  resolve(false);
  await run;
  expect(f.handle.current!.draftText()).toBe("");
  expect(readPersistedDraft("source")).toBe(`edited ${f.sourceDraft}`);
  expect(f.stored.get("source")).toEqual([attachment]);
  expect(f.sent).toEqual([]);
});
