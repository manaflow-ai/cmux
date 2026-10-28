// A Codex goal can stream snapshots faster than a person types. The prompt's ProseMirror view is
// independent of those snapshots; reconciling it for every token makes the next key wait behind a
// React render. This is a deterministic stream harness: callbacks stay live through refs, while an
// unchanged draft and caret keep one editor commit across the stream.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act, Profiler, useCallback, useRef } from "react";
import type { Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { MarkdownField } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a streaming goal leaves the prompt editor and caret out of the render loop", async () => {
  const { createRoot } = await import("react-dom/client");
  const handle = { current: null as MarkdownFieldHandle | null };
  const values: string[] = [];
  let commits = 0;
  let renderWork = 0;
  let draft = "";

  function StreamProbe({ tick }: { tick: number }) {
    const onChangeRef = useRef((value: string) => {
      draft = value;
      values.push(value);
    });
    onChangeRef.current = (value: string) => {
      draft = value;
      values.push(value);
    };
    const onChange = useCallback((value: string, _caret: number) => onChangeRef.current(value), []);
    const setHandle = useCallback((value: MarkdownFieldHandle | null) => {
      handle.current = value;
    }, []);
    return (
      <div data-stream-tick={tick}>
        <Profiler
          id="codex-goal-composer"
          onRender={(_id, _phase, actualDuration) => {
            commits += 1;
            renderWork += actualDuration;
          }}
        >
          <MarkdownField ref={setHandle} value={draft} selectionKey="codex-goal" onChange={onChange} />
        </Profiler>
      </div>
    );
  }

  root = createRoot(host);
  await act(async () => root!.render(<StreamProbe tick={0} />));
  for (let turn = 0; turn < 200 && !handle.current; turn += 1)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(handle.current).not.toBeNull();

  // This is the same work a running goal does: two snapshots can arrive between keystrokes. The
  // first render below carries the previous key's controlled value; the second carries only a
  // newer goal update. The editor must reconcile the former, but skip the latter.
  for (let tick = 1; tick <= 40; tick += 1) {
    await act(async () => root!.render(<StreamProbe tick={tick * 2} />));
    await act(async () => root!.render(<StreamProbe tick={tick * 2 + 1} />));
    await act(async () => handle.current!.insertTyped("x"));
  }

  expect(draft).toBe("x".repeat(40));
  expect(values.at(-1)).toBe(draft);
  // The parent receives two goal updates and one controlled-value update per key. The controlled
  // updates are the only ones that should reach the editor; the goal-only updates must preserve the
  // same field and caret while they stream.
  expect(commits).toBe(81);
  expect(renderWork).toBeGreaterThan(0);
});
