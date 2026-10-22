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
  let answered = 0;
  const reads: ((value: unknown) => void)[] = [];
  const saves: (() => void)[] = [];
  return {
    /// Every read the pane asked for.
    get asked() {
      return reads.length + answered;
    },
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
      answered += 1;
      await act(async () => read({ cwd, level }));
    },
  };
}

let shown: TrustAsk | undefined;
let renders: TrustAsk[] = [];
function Probe({
  source,
  sessionId,
  cwd = "/Users/you/src/cmux",
  family = "claude",
  local = true,
}: {
  source: ReturnType<typeof heldSource>["source"];
  sessionId: string;
  cwd?: string;
  family?: string;
  local?: boolean;
}) {
  shown = useFolderTrustAsk(source, { sessionId, cwd, family, prompts: 1 }, true, local);
  renders.push(shown);
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
  expect(shown!.blocked).toEqual({ reason: "trust.answerFirst", shownAbove: true });
});

// Leo 2026-10-19: a switch to another chat in the very same folder checked the folder's trust
// again. The folder is the same, so its answer is too: no read, and no frame that reads it.
test("another chat in the same folder keeps the folder's answer without reading it again", async () => {
  for (const local of [true, false]) {
    const trust = heldSource();
    const cwd = `/Users/you/src/same-${local}`;
    await act(async () => root.render(<Probe source={trust.source} sessionId="chat-6" cwd={cwd} local={local} />));
    await trust.answer("trusted", cwd);
    expect(shown!.trusted).toBe(true);
    const asked = trust.asked;

    renders = [];
    await act(async () => root.render(<Probe source={trust.source} sessionId="chat-7" cwd={cwd} local={local} />));
    // The other agent in the same folder: still the same folder.
    await act(async () =>
      root.render(<Probe source={trust.source} sessionId="chat-7" cwd={cwd} family="codex" local={local} />),
    );
    expect(trust.asked).toBe(asked);
    for (const render of renders) {
      expect(render.blocked).toBeUndefined();
      expect(render.trusted).toBe(true);
    }
  }
});
