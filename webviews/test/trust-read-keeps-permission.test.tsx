// Agent pane flicker (2026-10-19): an open permission card blinked out and back when the user
// switched tabs or workspaces and came back. The pane reads the chat folder's trust whenever the
// chat's folder, agent or session comes in (a mount, a chat switch, the summary landing after the
// attach), and while that read was in flight the bottom stack treated the chat as held behind the
// trust question: it dropped every permission card and panel, and put the asked calls back in the
// transcript, until the read answered. A read in flight asks nothing, so it holds nothing; only an
// open trust question or Don't trust does. Send stays off while it reads.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
type TrustAsk = ReturnType<typeof useFolderTrustAsk>;

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

/// A trust source whose reads and saves wait until the test answers them.
function heldSource() {
  const reads: ((value: unknown) => void)[] = [];
  const saves: (() => void)[] = [];
  return {
    source: {
      get: () => new Promise((resolve) => reads.push(resolve)),
      set: () => new Promise<void>((resolve) => saves.push(resolve)),
    },
    saved: async () => {
      const save = saves.shift()!;
      await act(async () => save());
    },
    answer: async (level: string, cwd = "/Users/you/src/cmux") => {
      const read = reads.shift()!;
      await act(async () => read({ cwd, level }));
    },
  };
}

let shown: TrustAsk | undefined;
function Probe({
  source,
  sessionId,
  cwd = "/Users/you/src/cmux",
}: {
  source: ReturnType<typeof heldSource>["source"];
  sessionId: string;
  cwd?: string;
}) {
  shown = useFolderTrustAsk(source, { sessionId, cwd, family: "claude", prompts: 1 });
  return null;
}

test("a trust read in flight never holds the chat's permission asks", async () => {
  const trust = heldSource();
  await act(async () => root.render(<Probe source={trust.source} sessionId="chat-1" />));
  // Reading: Send waits, the asks stay.
  expect(shown!.blocked).toEqual({});
  expect(shown!.holdsAsks).toBe(false);
  await trust.answer("trusted");
  expect(shown!.blocked).toBeUndefined();
  expect(shown!.holdsAsks).toBe(false);

  // Another chat in a folder the pane never read: the asks stay while it reads.
  await act(async () => root.render(<Probe source={trust.source} sessionId="chat-2" cwd="/Users/you/src/other" />));
  expect(shown!.blocked).toEqual({});
  expect(shown!.holdsAsks).toBe(false);
  await trust.answer("trusted", "/Users/you/src/other");
  expect(shown!.holdsAsks).toBe(false);
});

test("an open trust question holds the asks until it is answered", async () => {
  const trust = heldSource();
  const cwd = "/Users/you/src/unasked";
  await act(async () => root.render(<Probe source={trust.source} sessionId="chat-3" cwd={cwd} />));
  expect(shown!.holdsAsks).toBe(false);
  await trust.answer("unknown", cwd);
  expect(shown!.ask?.state).toBe("ask");
  expect(shown!.holdsAsks).toBe(true);
});

// Review of #22054 (greptile): an answer saved in one chat's folder dropped the read another
// folder had in flight, so that folder showed no question and Send went on.
test("an answer saved for another folder leaves this folder's read standing", async () => {
  const trust = heldSource();
  const first = "/Users/you/src/answered";
  const second = "/Users/you/src/next";
  await act(async () => root.render(<Probe source={trust.source} sessionId="chat-4" cwd={first} />));
  await trust.answer("unknown", first);
  expect(shown!.ask?.state).toBe("ask");
  // Trust in the first chat, then switch before the save lands.
  await act(async () => shown!.trust());
  await act(async () => root.render(<Probe source={trust.source} sessionId="chat-5" cwd={second} />));
  await trust.saved();
  await trust.answer("unknown", second);
  expect(shown!.ask).toEqual({ cwd: second, state: "ask" });
  expect(shown!.blocked).toEqual({ reason: "trust.answerFirst" });
});
