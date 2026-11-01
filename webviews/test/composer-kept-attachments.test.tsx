// Leo 2026-10-20: a composer draft's text came back and its pasted screenshots did not, after a
// quit, after reopening the chat and after archiving or deleting it and restoring it. acpmux keeps
// the text with the session; the host now keeps the chat's chips (chat.draftAttachments,
// AgentPaneDraftAttachments.swift) and every page that shows the chat again reads them back.
import { afterAll, afterEach, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { KEPT_ATTACHMENTS_SETTLE_MS, type KeptAttachments } from "../src/agent-session/acpmux/composer/keptAttachments";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

// A chip rests KEPT_ATTACHMENTS_SETTLE_MS before the page writes it; the test moves the clock.
beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  closePage();
  jest.useRealTimers();
  // Each test opens its chats fresh: the composer's remount cache (composerDraft.ts) is page
  // storage, and a prompt one test left there (its inline chips' tokens) must not fill the next
  // test's composer. It once did, which hid a test's chip that went in outside act.
  localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

/// The host's store as AgentPaneDraftAttachments.swift keeps it: by chat, contents once per chip
/// (a write without a chip's contents keeps the ones it has), nothing for an empty list.
class Host implements KeptAttachments {
  chats = new Map<string, ComposerAttachment[]>();
  writes: { sessionId: string; attachments: ComposerAttachment[] }[] = [];
  async read(sessionId: string) {
    return (this.chats.get(sessionId) ?? []).map((chip) => ({ ...chip }));
  }
  async write(sessionId: string, attachments: ComposerAttachment[]) {
    this.writes.push({ sessionId, attachments });
    const had = this.chats.get(sessionId) ?? [];
    const kept = attachments.flatMap((chip) => {
      if (chip.data || chip.kind === "text" || chip.kind === "link") return [chip];
      const before = had.find((old) => old.id === chip.id);
      return before?.data ? [{ ...chip, data: before.data }] : [];
    });
    if (kept.length) this.chats.set(sessionId, kept);
    else this.chats.delete(sessionId);
    return { held: kept.filter((chip) => chip.data).map((chip) => chip.id) };
  }
}

const screenshot = (index: number): ComposerAttachment => ({
  id: `shot-${index}`,
  kind: "image",
  name: `Screenshot ${index}.png`,
  mimeType: "image/png",
  size: 1_500_000,
  data: btoa(`png-bytes-${index}`),
});
const notes: ComposerAttachment = {
  id: "link-notes",
  kind: "link",
  name: "notes",
  mimeType: "inode/directory",
  size: 0,
  path: "/tmp/notes",
};

/// One chat page: a composer for `sessionId` with the host's store, as App.tsx renders it.
async function openPage(
  sessionId: string,
  store: KeptAttachments | undefined,
  options: { switching?: boolean; sent?: () => void } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId,
    summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 },
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={() => {
          options.sent?.();
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        switching={options.switching}
        handle={handle}
        keptAttachments={store}
      />,
    ),
  );
  await settle();
  return handle;
}

/// Closing the tab (or archiving the chat, which closes it): the page goes.
function closePage() {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
}

async function settle() {
  await act(async () => void jest.advanceTimersByTime(KEPT_ATTACHMENTS_SETTLE_MS + 20));
}

const shown = (handle: React.RefObject<ComposerHandle | null>) => handle.current?.wakeState().attachments ?? [];

test("reopening a chat brings back its pasted screenshots and attached folder", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => {
    for (const index of [1, 2, 3, 4]) page.current!.attach(screenshot(index));
    page.current!.attach(notes);
  });
  await settle();
  closePage();

  const reopened = await openPage("chat-a", store);
  expect(shown(reopened).map((chip) => chip.name)).toEqual([
    "Screenshot 1.png",
    "Screenshot 2.png",
    "Screenshot 3.png",
    "Screenshot 4.png",
    "notes",
  ]);
  expect(
    shown(reopened)
      .slice(0, 4)
      .map((chip) => chip.data),
  ).toEqual([1, 2, 3, 4].map((index) => btoa(`png-bytes-${index}`)));
  expect(shown(reopened).at(-1)?.path).toBe("/tmp/notes");
});

test("archiving or deleting a chat and restoring it later brings its chips back, to that chat only", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  // Archive closes the tab before the chips have rested: the page sends them as it goes.
  closePage();
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);

  // Other chats come and go meanwhile; none of them gets these chips.
  const other = await openPage("chat-b", store);
  expect(shown(other)).toEqual([]);
  closePage();

  // Unarchive (or reopening a deleted chat) opens the chat in a new tab with a new page.
  const restored = await openPage("chat-a", store);
  expect(shown(restored).map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(shown(restored)[0]?.data).toBe(btoa("png-bytes-1"));
});

test("sending the chips forgets them, so the chat reopens without them", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  expect(store.chats.has("chat-a")).toBe(true);
  let sent = 0;
  const sending = await openPage("chat-a", store, { sent: () => (sent += 1) });
  act(() => {
    sending.current!.send();
  });
  await settle();
  expect(sent).toBe(1);
  expect(store.chats.has("chat-a")).toBe(false);
  closePage();
  const reopened = await openPage("chat-a", store);
  expect(shown(reopened)).toEqual([]);
});

test("a page that opens empty never erases the chips it is about to get back", async () => {
  const store = new Host();
  store.chats.set("chat-a", [screenshot(1)]);
  let release: () => void = () => {};
  const slow: KeptAttachments = {
    read: (sessionId) => new Promise((resolve) => (release = () => resolve(store.read(sessionId)))),
    write: (sessionId, attachments) => store.write(sessionId, attachments),
  };
  const page = await openPage("chat-a", slow);
  expect(store.writes).toEqual([]);
  await act(async () => release());
  await settle();
  expect(shown(page).map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(store.writes).toEqual([]);
});

test("a chip's contents go to the host once; later writes name it without them", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  act(() => page.current!.attach(screenshot(2)));
  await settle();
  const last = store.writes.at(-1)!.attachments;
  expect(last.map((chip) => [chip.id, Boolean(chip.data)])).toEqual([
    ["shot-1", false],
    ["shot-2", true],
  ]);
  expect(store.chats.get("chat-a")?.map((chip) => chip.data)).toEqual([btoa("png-bytes-1"), btoa("png-bytes-2")]);
});

// Regression (SW-00): a file's full-resolution original can arrive after its
// preview was already saved. It updates the existing chip, without changing its ID.
test("an original upload finishing after the preview was kept updates that draft", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  expect(store.chats.get("chat-a")?.[0]?.originalPath).toBeUndefined();
  const before = store.writes.length;

  act(() =>
    page.current!.attach({
      ...screenshot(1),
      originalPath: "/remote/Screenshot 1.png",
      originalName: "Screenshot 1.png",
    }),
  );
  await settle();

  expect(store.writes).toHaveLength(before + 1);
  // The host already holds the preview bytes: the metadata update sends no second image copy.
  expect(store.writes.at(-1)!.attachments[0]?.data).toBeUndefined();
  closePage();
  const restored = await openPage("chat-a", store);
  expect(shown(restored)[0]?.originalPath).toBe("/remote/Screenshot 1.png");
  expect(shown(restored)[0]?.originalName).toBe("Screenshot 1.png");
  expect(shown(restored)[0]?.data).toBe(btoa("png-bytes-1"));
});

// The upload may finish inside the 300-ms draft settle window. Its newer path
// must replace the pending preview-only write before that timer submits.
test("an original upload updates the pending draft snapshot before it settles", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(2)));
  act(() =>
    page.current!.attach({
      ...screenshot(2),
      originalPath: "/remote/Screenshot 2.png",
      originalName: "Screenshot 2.png",
    }),
  );
  await settle();

  expect(store.writes).toHaveLength(1);
  expect(store.chats.get("chat-a")?.[0]?.originalPath).toBe("/remote/Screenshot 2.png");
  closePage();
  const restored = await openPage("chat-a", store);
  expect(shown(restored)[0]?.originalPath).toBe("/remote/Screenshot 2.png");
});

test("an image original path cleared on the same chip is cleared in its saved draft", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach({ ...screenshot(3), originalPath: "/remote/old.png" }));
  await settle();

  act(() => page.current!.attach(screenshot(3)));
  await settle();
  closePage();

  const restored = await openPage("chat-a", store);
  expect(shown(restored)[0]?.originalPath).toBeUndefined();
  expect(shown(restored)[0]?.data).toBe(btoa("png-bytes-3"));
});

test("moving to another chat shows that chat's chips; a harness switch carries the ones held", async () => {
  const store = new Host();
  store.chats.set("chat-c", [screenshot(3)]);
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  const moved = await openPage("chat-c", store);
  expect(shown(moved).map((chip) => chip.id)).toEqual(["shot-3"]);
  // Back on chat-a, its own chip is there.
  const back = await openPage("chat-a", store);
  expect(shown(back).map((chip) => chip.id)).toEqual(["shot-1"]);
  // A harness switch starts a new session: the chips held move to it, as the typed prompt does.
  await openPage("", store, { switching: true });
  const switched = await openPage("chat-new", store, { switching: true });
  expect(shown(switched).map((chip) => chip.id)).toEqual(["shot-1"]);
  await openPage("chat-new", store);
  expect(store.chats.get("chat-new")?.map((chip) => chip.id)).toEqual(["shot-1"]);
});

test("sending a chip before it rests never brings it back", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  // Paste and Enter at once: the chip goes with the prompt before its write rests.
  act(() => page.current!.attach(screenshot(1)));
  act(() => {
    page.current!.send();
  });
  await settle();
  expect(store.chats.has("chat-a")).toBe(false);
  closePage();
  const reopened = await openPage("chat-a", store);
  expect(shown(reopened)).toEqual([]);
});

test("a chip put back right after its send (a refusal) stays kept", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  act(() => {
    page.current!.send();
  });
  // The host refused the prompt: the composer gets its chip back before the clear rests.
  act(() => page.current!.restore("", [screenshot(1)]));
  await settle();
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);
  closePage();
  const reopened = await openPage("chat-a", store);
  expect(shown(reopened).map((chip) => chip.data)).toEqual([btoa("png-bytes-1")]);
});

test("a chip the host no longer holds goes again with its contents", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  // Sent: the host forgets it.
  act(() => {
    page.current!.send();
  });
  await settle();
  expect(store.chats.has("chat-a")).toBe(false);
  // Edit on the failed prompt puts the same chip back: the host has no file for it now.
  act(() => page.current!.restore("", [screenshot(1)]));
  await settle();
  expect(store.writes.at(-1)!.attachments.map((chip) => Boolean(chip.data))).toEqual([true]);
  expect(store.chats.get("chat-a")?.map((chip) => chip.data)).toEqual([btoa("png-bytes-1")]);
});

test("a page going away sends a write still resting", async () => {
  const store = new Host();
  const page = await openPage("chat-a", store);
  // Async: the field tells the composer of the chip's inline node in a microtask (MarkdownField
  // `tellInlineViews`), which has to land inside act. The write still rests: no timer moves.
  await act(async () => page.current!.attach(screenshot(1)));
  // The tab closes: the web page hides before React unmounts anything.
  act(() => {
    window.dispatchEvent(new window.Event("pagehide"));
  });
  expect(store.writes.map((write) => write.attachments.map((chip) => chip.id))).toEqual([["shot-1"]]);
});
