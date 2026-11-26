// The New Tab page at a chat list of any size, for the whole-list detector
// (test/new-tab-no-whole-list-passes.test.tsx) and its bench (bench/new-tab-scale.bench.tsx).
//
// The real page renders in JSDOM over SIZE listed chats: Minimal (NewTabScreen, its location strip
// included) or Classic (NewTabPage). Two moves are measured:
//   key     one keystroke in the field (the text grows a letter);
//   update  one chat's status changes, the way the pane makes the next list (direct.ts
//           `sessionEntryList`: a new array with that one entry replaced, `noteReplaced`).
// With `count`, the chat list is a counting Proxy: every element the page's own code reads of it
// counts, so a pass over the whole list shows as SIZE reads, whatever it computes. React's
// development build reads props to log a render's changes (`addObjectDiffToProperties`); those
// reads are React's, not the page's, and are left out.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat, session } from "../../src/gallery/fixtures/acpmux";
import { NewTabScreen } from "../../src/agent-session/acpmux/newtab/NewTabScreen";
import { NewTabPage } from "../../src/agent-session/acpmux/NewTabPage";
import { proseMirrorGlobals } from "../../src/agent-session/acpmux/promptFieldTesting";
import type { MarkdownFieldElement } from "../../src/agent-session/acpmux/MarkdownField";
import { noteReplaced } from "../../src/agent-session/acpmux/sessionIndex";
import type { AcpmuxSessionEntry } from "../../src/agent-session/acpmux/sessionList";
import { settleReact } from "./domTeardown";

const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "MutationObserver",
  "getSelection",
  "Element",
  "getComputedStyle",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;

// The host's lists, as App.tsx keeps them (memoized): the same arrays on every render.
const PROJECTS = [{ cwd: "/Users/me/fun/project-1", label: "project-1" }];
const KNOWN = ["/Users/me/fun/project-1"];
const HOME = "/Users/me";

export type Look = "minimal" | "classic";
export type UpdateKind = "status" | "activity";

/// SIZE chats over 40 folders, a fifth on another machine, a few on Cloud: the shapes the page's
/// folder, machine and recent-chat lists read.
export function scaleSessions(size: number): AcpmuxSessionEntry[] {
  const now = Date.now();
  return Array.from({ length: size }, (_, index) =>
    session({
      sessionId: `s${index}`,
      title: `chat ${index} about the omnibar`,
      cwd: `${HOME}/fun/project-${index % 40}`,
      updatedAt: now - index * 60_000,
      activityAt: now - index * 60_000,
      ...(index % 5 === 4 ? { peer: "big-box", host: "big-box" } : {}),
      ...(index % 97 === 3 ? { host: "cloud-1", hostKind: "cloud" as const } : {}),
    }),
  );
}

/// `entries` behind a Proxy that adds each element the page reads (an index, `for … of`, `.filter`,
/// a spread) to `counter`.
function counted(entries: AcpmuxSessionEntry[], counter: { n: number }): AcpmuxSessionEntry[] {
  return new Proxy(entries, {
    get(target, key, receiver) {
      if (typeof key === "string" && key.charCodeAt(0) >= 48 && key.charCodeAt(0) <= 57) {
        if (!(new Error().stack ?? "").includes("addObjectDiffToProperties")) counter.n += 1;
      }
      return Reflect.get(target, key, receiver);
    },
  });
}

export type NewTabAtScale = {
  /// One key: the field's text grows by `letter`.
  key(letter: string): Promise<void>;
  /// One chat changes, as the pane lists the change: `status` flips its working dot, `activity` is
  /// a working chat's event (its activity moves to now).
  update(kind?: UpdateKind): Promise<void>;
  /// Element reads of the chat list since the last reset (0 without `count`).
  reads(): number;
  reset(): void;
  close(): Promise<void>;
};

/// The New Tab page over `size` chats, mounted, its field up and holding `seed`.
export async function mountNewTab(
  size: number,
  options: { look?: Look; count?: boolean; seed?: string } = {},
): Promise<NewTabAtScale> {
  const look = options.look ?? "minimal";
  const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const scope = globalThis as Record<string, unknown>;
  const saved = new Map<string, unknown>(KEYS.map((key) => [key, scope[key]]));
  Object.assign(scope, {
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.assign(dom.window, { ResizeObserver: scope.ResizeObserver });
  const container = dom.window.document.getElementById("root")!;
  const root: Root = createRoot(container);
  const counter = { n: 0 };
  const wrap = (entries: AcpmuxSessionEntry[]) => (options.count ? counted(entries, counter) : entries);
  let entries = scaleSessions(size);
  let list = wrap(entries);
  let flips = 0;
  const render = (sessions: AcpmuxSessionEntry[]) =>
    root.render(
      look === "classic" ? (
        <NewTabPage
          snapshot={noChat(sessions)}
          home={HOME}
          knownProjects={KNOWN}
          projects={PROJECTS}
          onSubmit={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
        />
      ) : (
        <NewTabScreen
          snapshot={noChat(sessions)}
          home={HOME}
          projects={PROJECTS}
          knownProjects={KNOWN}
          onAsk={() => {}}
          onOpen={() => {}}
          onSearch={() => {}}
          onShell={() => {}}
          onJump={() => {}}
          onOpenSession={() => {}}
          onShowAll={() => {}}
        />
      ),
    );
  await act(async () => render(list));
  const field = container.querySelector<MarkdownFieldElement>(
    look === "classic" ? ".acpmux-newtab-field" : ".nt-field",
  );
  if (!field) throw new Error(`the ${look} New Tab page has no field`);
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  let text = "";
  const write = async () =>
    act(async () => {
      field.acpmuxMarkdownField!.writeText(text, text.length, text.length);
      // The classic page lists its rows only while its field has the keyboard.
      editor.focus();
      editor.dispatchEvent(new dom.window.FocusEvent("focusin", { bubbles: true }));
    });
  text = options.seed ?? "c";
  await write();
  await settleReact();
  return {
    async key(letter) {
      text += letter;
      await write();
    },
    async update(kind = "status") {
      const at = flips++ % Math.max(1, entries.length);
      const before = list;
      const next = entries.slice();
      const entry = next[at]!;
      const now = Date.now() + flips;
      next[at] =
        kind === "activity"
          ? { ...entry, updatedAt: now, activityAt: now }
          : {
              ...entry,
              status: entry.status === "working" ? "idle" : "working",
            };
      entries = next;
      list = wrap(next);
      noteReplaced(before, list, [at]);
      await act(async () => render(list));
    },
    reads: () => counter.n,
    reset: () => {
      counter.n = 0;
    },
    async close() {
      act(() => root.unmount());
      await settleReact();
      for (const [key, value] of saved) {
        if (value === undefined) delete scope[key];
        else scope[key] = value;
      }
      dom.window.close();
    },
  };
}
