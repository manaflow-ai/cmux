// A streamed frame's draw of the reply's row leaves room for a key (Leo, 2026-11-17: "man the difference
// typing on terminal vs gui is def noticeable rn"). While a reply streamed, a key typed into the chat's
// composer waited 84-90 ms p95 before the page's keydown listener ran (Mac typing bench, chat while its own
// reply streams): the renderer's main thread was in the transcript's render of a streamed frame. That render
// was a sync render in the frame's microtask (`useSyncExternalStore`, React's SyncLane), which no input can
// cut into; every chat page shares one renderer, so another chat's stream held the key too.
//
// The row's draw is a transition now: React renders it from a scheduler task, in 5 ms slices with input
// between them. This checks the scheduling itself: after the store moves on, the draw has not run in the
// microtasks that follow (where the key could not go first), and it has run a task later.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
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

afterAll(async () => {
  root?.unmount();
  await teardownDom(saved, { scope });
});

// Yields whole tasks (setTimeout 0 runs after React's scheduler task) until `drew()` holds, at most 200.
const drawnBy = async (drew: () => boolean) => {
  for (let i = 0; i < 200 && !drew(); i += 1) await new Promise<void>((resolve) => setTimeout(resolve, 0));
};
const microtasks = async () => {
  for (let i = 0; i < 20; i += 1) await Promise.resolve();
};

test("a streamed frame's draw of the reply's row runs in a task a key can go before, not in a microtask", async () => {
  const { createRoot } = await import("react-dom/client");
  const { streamingRow, useStreamingRow } = await import("../src/agent-session/acpmux/streamingRow");
  const drawn: (string | undefined)[] = [];
  function Transcript() {
    const live = useStreamingRow(true);
    drawn.push(live?.row.text);
    return <p>{live?.row.text ?? ""}</p>;
  }
  root = createRoot(host);
  root.render(<Transcript />);
  await drawnBy(() => drawn.length > 0);
  expect(drawn.at(-1)).toBeUndefined();

  const row = (text: string, version: number) =>
    ({ id: "reply", kind: "assistant", text, version, streaming: true }) as unknown as AcpmuxRow;
  const before = row("Hello", 1);
  for (const [text, version] of [
    ["Hello, wor", 2],
    ["Hello, world. Here", 3],
  ] as const) {
    streamingRow.set(row(text, version), before);
    await microtasks();
    // Base: the store's sync render already drew the frame here, in the microtask after the frame.
    expect(drawn.at(-1)).not.toBe(text);
    await drawnBy(() => drawn.at(-1) === text);
    expect(drawn.at(-1)).toBe(text);
    expect(host.textContent).toBe(text);
  }

  // The pane's own redraw clears the store; the row then draws from the pane's rows again.
  streamingRow.clear();
  await drawnBy(() => drawn.at(-1) === undefined);
  expect(drawn.at(-1)).toBeUndefined();
});
