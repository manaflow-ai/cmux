// Leo, 2026-10-19: the permission UI flickered on every tab or workspace switch, and on every
// workspace create or close. The folder trust ask reset to "reading" whenever the chat changed:
// Send was blocked, the permission panel and asks left the tree and the access chip lost its
// folder grant until acpmux answered `acp.trust.get` again (up to 1.5 s). A folder whose trust the
// pane already read keeps that answer from the switch's first render; the read only refreshes it.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
type TrustSource = import("../src/agent-session/acpmux/folderTrust").TrustSource;

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Seen = { sessionId: string; blocked: boolean; trusted: boolean };

/// A source that answers each folder's first read at once and leaves every later read pending,
/// as a slow acpmux does after a switch.
function source(levels: Record<string, "trusted" | "untrusted" | "unknown">): TrustSource {
  const read = new Set<string>();
  return {
    get: (cwd) => {
      if (read.has(cwd)) return new Promise(() => {});
      read.add(cwd);
      return Promise.resolve({ cwd, level: levels[cwd], decided: true });
    },
    set: () => Promise.resolve({}),
  };
}

function Probe(props: { trust: TrustSource; sessionId: string; cwd: string; seen: Seen[] }) {
  const ask = useFolderTrustAsk(props.trust, { sessionId: props.sessionId, cwd: props.cwd, prompts: 0 });
  // Each committed render, before the browser paints it (a render React discards is never drawn).
  React.useLayoutEffect(() => {
    props.seen.push({ sessionId: props.sessionId, blocked: Boolean(ask.blocked), trusted: ask.trusted });
  });
  return null;
}

async function show(trust: TrustSource, sessionId: string, cwd: string, seen: Seen[]) {
  await act(async () => root.render(<Probe trust={trust} sessionId={sessionId} cwd={cwd} seen={seen} />));
}

test("switching back to a chat in a folder read before draws its trust from the first render", async () => {
  const trust = source({ "/work/a": "trusted", "/work/b": "trusted" });
  const seen: Seen[] = [];
  await show(trust, "chat-a", "/work/a", seen);
  await show(trust, "chat-b", "/work/b", seen);
  expect(seen.at(-1)).toEqual({ sessionId: "chat-b", blocked: false, trusted: true });
  seen.length = 0;
  // Back to chat A: acpmux has not answered this read, the pane still knows the folder.
  await show(trust, "chat-a", "/work/a", seen);
  expect(seen.length).toBeGreaterThan(0);
  expect(seen.filter((render) => render.blocked || !render.trusted)).toEqual([]);
});

test("a folder never read before still waits for its answer", async () => {
  const trust = source({ "/work/new": "trusted" });
  const seen: Seen[] = [];
  await show(trust, "chat-new", "/work/new-unread", seen);
  expect(seen[0]).toEqual({ sessionId: "chat-new", blocked: true, trusted: false });
});

test("an answer given while a read is in flight is not undone by that read", async () => {
  let answerRead: (value: unknown) => void = () => {};
  const reads = new Map<string, number>();
  const trust: TrustSource = {
    get: (cwd) => {
      const count = (reads.get(cwd) ?? 0) + 1;
      reads.set(cwd, count);
      if (count === 1) return Promise.resolve({ cwd, level: "unknown", decided: true });
      return new Promise((resolve) => (answerRead = resolve));
    },
    set: () => Promise.resolve({}),
  };
  let latest: ReturnType<typeof useFolderTrustAsk> | undefined;
  function Answering(props: { sessionId: string; cwd: string }) {
    latest = useFolderTrustAsk(trust, { sessionId: props.sessionId, cwd: props.cwd, prompts: 0 });
    return null;
  }
  await act(async () => root.render(<Answering sessionId="chat-q" cwd="/work/q" />));
  await act(async () => root.render(<Answering sessionId="chat-r" cwd="/work/r" />));
  // Back to chat Q: its known "unknown" asks at once while the second read is out; the user trusts.
  await act(async () => root.render(<Answering sessionId="chat-q" cwd="/work/q" />));
  expect(latest!.ask?.state).toBe("ask");
  await act(async () => latest!.trust());
  expect(latest!.trusted).toBe(true);
  await act(async () => answerRead({ cwd: "/work/q", level: "unknown", decided: true }));
  expect(latest!.trusted).toBe(true);
  expect(latest!.blocked).toBeUndefined();
});
