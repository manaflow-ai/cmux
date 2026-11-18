// cmux#46201: an existing chat's composer names the folder it is in. The location strip over the
// card is a new chat's only (locationRow.ts `showsLocationRow`), so once the chat has its first send
// the quiet row under the card carries the folder as a plain label after the mode chip
// (ChatFolderChip.tsx). Before this, a started chat's footer showed only the mode and the model.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { chat, noChat, summary, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

async function render(snapshot: AcpmuxSnapshot, extra: Record<string, unknown> = {}) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        {...extra}
      />,
    ),
  );
}

const strip = () => host.querySelector(".acpmux-composer-strip:not([aria-hidden='true'])");
const folderChip = () => host.querySelector<HTMLElement>(".acpmux-composer-foot .acpmux-chat-folder");

function startedChat(cwd: string | undefined, fields: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}) {
  const started = chat([user("Add retries", 1), summary(1, { status: "completed" })]);
  return {
    ...started,
    sessionId: "old-chat",
    summary: { sessionId: "old-chat", harness: "claude", turnCount: 1, ...(cwd ? { cwd } : {}), ...fields },
  } as AcpmuxSnapshot;
}

test("a started chat names its folder in the composer's quiet row", async () => {
  await render(startedChat("/Users/you/src/app"));
  expect(strip()).toBeNull();
  const chip = folderChip();
  expect(chip).not.toBeNull();
  expect(chip!.textContent).toBe("app");
  // The whole path is one hover away.
  expect(chip!.title).toBe("/Users/you/src/app");
});

test("a new chat names its folder in the strip only, never twice", async () => {
  await render(
    noChat([], {
      sessionId: "new-chat",
      summary: { sessionId: "new-chat", harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
    }),
  );
  expect(strip()).not.toBeNull();
  expect(folderChip()).toBeNull();
});

test("a Cloud chat names the folder it works in on its machine", async () => {
  await render(startedChat("/home/cmux/work/api", { hostKind: "cloud" }));
  expect(folderChip()!.textContent).toBe("api");
  // Still in the fresh folder its machine made for it: that folder's name, never No folder.
  await render(startedChat("/home/cmux/chats/s-1", { hostKind: "cloud" }));
  expect(folderChip()!.textContent).toBe("s-1");
});

test("a reopened chat whose folder is not known yet draws no folder chip", async () => {
  await render(startedChat(undefined));
  expect(folderChip()).toBeNull();
});

test("startedChatFolderFace: the one rule for what the chip says", async () => {
  const { startedChatFolderFace } = await import("../src/agent-session/acpmux/ChatFolderChip");
  expect(startedChatFolderFace(undefined)).toBeUndefined();
  expect(startedChatFolderFace({ cwd: "/Users/you/src/cmux/" })).toEqual({
    label: "cmux",
    title: "/Users/you/src/cmux/",
  });
  // On an SSH machine `~/chats/api` is a project like any other.
  expect(startedChatFolderFace({ cwd: "/home/cmux/chats/api", hostKind: "local" })).toEqual({
    label: "api",
    title: "/home/cmux/chats/api",
  });
});
