// A chat switch reads the new chat's kept chips (composer/keptAttachments.ts) right after it commits.
// When the read finds none, the composer renders nothing again: the read used to set a `readFor`
// state, which rendered the whole composer once more before the switch's first frame
// (bench/settled-page.bench.ts, chat_switch). Chips held by a harness switch are still kept for the
// new session, and chips the read finds still come back.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
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
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useKeptAttachments } = await import("../src/agent-session/acpmux/composer/keptAttachments");
const { webSwapHold } = await import("../src/pages/shared/webSwap");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const chip = (id: string): ComposerAttachment => ({ id, name: `${id}.png` }) as ComposerAttachment;
/// Yields one task at a time until `ready` holds, so a test waits for the value it asserts on next (a
/// kept write rests KEPT_ATTACHMENTS_SETTLE_MS first, so the bound is wall time, not turns).
const until = (ready: () => boolean, what: string) =>
  act(async () => {
    for (const deadline = Date.now() + 5_000; !ready(); ) {
      if (Date.now() > deadline) throw new Error(`${what} never came`);
      await new Promise((done) => setTimeout(done, 0));
    }
    // One task more, so what follows the awaited read or write (its render) has run.
    await new Promise((done) => setTimeout(done, 0));
  });

async function page(kept: Record<string, ComposerAttachment[]>, held: ComposerAttachment[], carrying: boolean) {
  const writes: { sessionId: string; ids: string[] }[] = [];
  const reads: string[] = [];
  const store = {
    read: async (sessionId: string) => {
      reads.push(sessionId);
      return kept[sessionId] ?? [];
    },
    write: async (sessionId: string, attachments: ComposerAttachment[]) => {
      writes.push({ sessionId, ids: attachments.map((a) => a.id) });
      return { held: attachments.map((a) => a.id) };
    },
  };
  const renders: { sessionId: string; ids: string[] }[] = [];
  let show: (sessionId: string) => void = () => undefined;
  // The pane picks the chat and the composer takes it as a prop, as ComposerFrame does.
  function Probe({ sessionId }: { sessionId: string }) {
    const [attachments, setAttachments] = useState(held);
    useKeptAttachments(sessionId, attachments, setAttachments, store, () => carrying);
    renders.push({ sessionId, ids: attachments.map((a) => a.id) });
    return null;
  }
  function Pane() {
    const [sessionId, setSessionId] = useState("chat-a");
    show = setSessionId;
    return createElement(Probe, { sessionId });
  }
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () => root.render(createElement(Pane)));
  await until(() => reads.includes("chat-a"), "the read of chat-a");
  return {
    renders,
    writes,
    switchTo: async (sessionId: string) => {
      await act(async () => show(sessionId));
      await until(() => reads.includes(sessionId), `the read of ${sessionId}`);
    },
    close: async () => {
      await act(async () => root.unmount());
      host.remove();
    },
  };
}

test("a switch to a chat with no kept chips renders the composer once", async () => {
  const p = await page({}, [], false);
  const before = p.renders.length;
  await p.switchTo("chat-b");
  expect(p.renders.slice(before)).toEqual([{ sessionId: "chat-b", ids: [] }]);
  // No write rests or is out (the composer's hold on a web update says so), so none comes.
  expect(webSwapHold(dom.window.document)).toBeNull();
  expect(p.writes).toEqual([]);
  await p.close();
});

test("a switch to a chat with kept chips brings them back", async () => {
  const p = await page({ "chat-b": [chip("shot")] }, [], false);
  await p.switchTo("chat-b");
  expect(p.renders.at(-1)).toEqual({ sessionId: "chat-b", ids: ["shot"] });
  await p.close();
});

test("chips a harness switch carries are kept for the new session with no extra render", async () => {
  const p = await page({}, [chip("held")], true);
  const before = p.renders.length;
  await p.switchTo("chat-b");
  expect(p.renders.slice(before)).toEqual([{ sessionId: "chat-b", ids: ["held"] }]);
  await until(() => p.writes.some((w) => w.sessionId === "chat-b"), "the write of chat-b's carried chips");
  expect(p.writes.filter((w) => w.sessionId === "chat-b")).toEqual([{ sessionId: "chat-b", ids: ["held"] }]);
  await p.close();
});
