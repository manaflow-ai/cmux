// The restored tail's first render leaves room for the socket (Leo, 2026-11-22: "get that gui agent chat
// sped up to be nearly as fast as the terminal coming back ... the agent gui needs that too").
//
// At relaunch the pane draws the tail the app host kept before the handshake (App.tsx watchRestoredTail),
// under the copy of the last frame. That render mounts the whole pane. As a default-lane update it ran in
// one piece (about 320 ms on the restart bench, PROFILE=1 rtt50), and acpmux's `initialize` answer waited
// behind it, so the attach went out that much later. It is a transition now (paneSnapshotLane.ts
// `drawRestoredTail`), and the direct client's first snapshot of the same chat redraws as one too.
// These check, with React's real scheduler (no act()):
// - a socket message that comes in while the pane renders the restored tail is handled before that render
//   ends, and the tail still commits whole;
// - the client's first snapshot of the restored chat is not drawn as a first frame (at once).
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Root } from "react-dom/client";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    // Real scheduling, not act()'s queue: the test reads when React renders.
    IS_REACT_ACT_ENVIRONMENT: false,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

beforeEach(() => {
  root?.unmount();
  root = undefined;
});

afterAll(async () => {
  root?.unmount();
  await teardownDom(saved, { scope });
});

const task = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const until = async (done: () => boolean) => {
  for (let i = 0; i < 2000 && !done(); i += 1) await task();
  expect(done()).toBe(true);
};

const SESSION = "chat-a";
const row = (id: string, kind: string, text: string) => ({ id, kind, text, version: 1 }) as unknown as AcpmuxRow;
const tail = (count: number, connection: string): AcpmuxSnapshot =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    connection,
    sessionId: SESSION,
    isWorking: false,
    sessions: [],
    queue: [],
    rows: Array.from({ length: count }, (_, index) =>
      row(`turn-${index}`, index % 2 ? "assistant" : "user", `line ${index}`),
    ),
  }) as unknown as AcpmuxSnapshot;

const busy = (ms: number) => {
  const end = performance.now() + ms;
  while (performance.now() < end);
};

/// The pane before the handshake: nothing drawn, then the restored tail through `draw` (App.tsx's
/// watchRestoredTail callback). Answers whether the tail had committed when a socket message that came in
/// at the render's start was handled.
async function socketDuringRestoredTail(draw: (set: () => void) => void): Promise<boolean> {
  const React = await import("react");
  const { createRoot } = await import("react-dom/client");
  let commits = 0;
  let rendering: (() => void) | undefined;
  const api: { set?: (next: AcpmuxSnapshot) => void } = {};
  function Row({ value }: { value: AcpmuxRow }) {
    busy(0.5);
    rendering?.();
    return <p>{value.text}</p>;
  }
  function Pane() {
    const [snapshot, setSnapshot] = React.useState<AcpmuxSnapshot>();
    api.set = setSnapshot;
    React.useLayoutEffect(() => {
      if (snapshot) commits += 1;
    }, [snapshot]);
    return (
      <div>
        {snapshot?.rows.map((value) => (
          <Row key={value.id} value={value} />
        ))}
      </div>
    );
  }
  root = createRoot(host);
  root.render(<Pane />);
  await until(() => api.set !== undefined);
  const handled: boolean[] = [];
  let queued = false;
  rendering = () => {
    if (queued) return;
    queued = true;
    // acpmux's `initialize` answer, a task of its own.
    setTimeout(() => handled.push(commits > 0), 0);
  };
  const restored = tail(200, "connecting");
  setTimeout(() => draw(() => api.set!(restored)), 0);
  await until(() => handled.length > 0 && commits > 0);
  expect(host.querySelectorAll("p").length).toBe(200);
  return handled[0]!;
}

test("a socket message that comes in while the pane renders the restored tail is handled before it commits", async () => {
  const { drawRestoredTail } = await import("../src/agent-session/acpmux/paneSnapshotLane");
  expect(await socketDuringRestoredTail(drawRestoredTail)).toBe(false);
});

test("as a default-lane update the restored tail's render holds the socket message until it commits", async () => {
  // What the pane did before: the render ran in one piece.
  expect(await socketDuringRestoredTail((set) => set())).toBe(true);
});

test("the client's first snapshot of the restored chat redraws as a transition, another chat's at once", async () => {
  const { drawsAtOnce } = await import("../src/agent-session/acpmux/paneSnapshotLane");
  const restored = tail(200, "connecting");
  expect(drawsAtOnce(restored, tail(200, "connecting"))).toBe(false);
  expect(drawsAtOnce(restored, { ...tail(200, "connecting"), sessionId: "chat-b" } as AcpmuxSnapshot)).toBe(true);
  expect(drawsAtOnce(undefined, tail(200, "connecting"))).toBe(true);
});
