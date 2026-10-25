import { afterEach, expect, jest, test } from "bun:test";
import type { editor } from "monaco-editor/editor/editor.api.js";
import { EditorStore, type CodeView, type EditorDocument } from "../src/pages/editor/store";
import { LineReveal } from "../src/pages/editor/lineReveal";
import { EDITOR_REVEAL, type EditorConfig } from "../src/pages/editor/host";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { FileLocation } from "../src/fileLocation";

function host(config: EditorConfig) {
  const listeners = new Map<string, (value: unknown) => void>();
  const client: PageClient = {
    async call<R>() {
      return config as R;
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      listeners.set(stream, (value) => onEvent(value as E, 1));
      return () => {
        listeners.delete(stream);
      };
    },
    handle: () => () => {},
  };
  return { client, emit: (location: unknown) => listeners.get(EDITOR_REVEAL)?.(location), listeners };
}

function codeView() {
  const loaded: EditorDocument[] = [];
  const reveals: FileLocation[] = [];
  const view: CodeView = {
    load: (document) => {
      loaded.push(document);
    },
    reveal: (location) => {
      reveals.push(location);
    },
    text: () => "unsaved edit",
    version: () => 2,
    setReadOnly: () => {},
  };
  return { view, loaded, reveals };
}

const config: EditorConfig = { path: "/repo/app.ts", text: "one\ntwo\n", hash: "a", location: { line: 42, column: 7 } };

test("open config retains its position while Monaco loads, including large-file plain text", async () => {
  const { client } = host({ ...config, size: 50_000_000 });
  const store = new EditorStore(client);
  await store.start();
  const { view, loaded } = codeView();
  store.attachView(view);
  expect(loaded[0]?.location).toEqual({ line: 42, column: 7 });
  expect(loaded[0]?.size).toBe(50_000_000);
  store.dispose();
});

test("reused tabs reveal in place without reloading or replacing unsaved text", async () => {
  const { client, emit, listeners } = host(config);
  const store = new EditorStore(client);
  const { view, loaded, reveals } = codeView();
  store.attachView(view);
  await store.start();
  emit({ line: 2, endLine: 3 });
  expect(reveals).toEqual([{ line: 2, endLine: 3 }]);
  expect(loaded).toHaveLength(1);
  expect(view.text()).toBe("unsaved edit");
  for (const line of [0, -1, 1.5, 10_000_001, "42", true]) emit({ line });
  expect(reveals).toHaveLength(1);
  store.dispose();
  expect(listeners.size).toBe(0);
});

test("a reveal between config and Monaco mount replaces the pending position", async () => {
  const { client, emit } = host(config);
  const store = new EditorStore(client);
  await store.start();
  emit({ line: 12 });
  const { view, loaded } = codeView();
  store.attachView(view);
  expect(loaded[0]?.location).toEqual({ line: 12 });
  store.dispose();
});

afterEach(() => jest.useRealTimers());

function editorTarget(height = 640) {
  let layout: ((event: { height: number }) => void) | undefined;
  const centers: unknown[] = [];
  let position: unknown;
  let centered: unknown;
  let decoration: unknown;
  let clears = 0;
  const target = {
    getModel: () => ({ getLineCount: () => 50, getLineMaxColumn: () => 8 }),
    setPosition: (value: unknown) => {
      position = value;
    },
    // Recorded as [line, scroll type]; the column is checked in src/pages/editor/lineReveal.test.ts.
    revealPositionInCenter: (value: { lineNumber: number }, scrollType: number) => {
      centered = [value.lineNumber, scrollType];
      centers.push(centered);
    },
    focus: () => {},
    getLayoutInfo: () => ({ height }),
    onDidLayoutChange: (listener: typeof layout) => {
      layout = listener;
      return {
        dispose: () => {
          layout = undefined;
        },
      };
    },
    createDecorationsCollection: (value: unknown) => {
      decoration = value;
      return {
        clear: () => {
          clears++;
        },
      };
    },
  } as unknown as editor.IStandaloneCodeEditor;
  return {
    target,
    centers,
    layout: (height: number) => layout?.({ height }),
    listening: () => layout !== undefined,
    position: () => position,
    centered: () => centered,
    decoration: () => decoration,
    clears: () => clears,
  };
}

test("Monaco clamps the cursor and range and removes the highlight after 1.5 seconds", () => {
  jest.useFakeTimers();
  const target = editorTarget();
  const reveal = new LineReveal(target.target);
  reveal.reveal({ line: 42, column: 7, endLine: 100 });
  expect(target.position()).toEqual({ lineNumber: 42, column: 7 });
  expect(target.centered()).toEqual([42, 1]);
  expect(target.decoration()).toMatchObject([
    { range: { startLineNumber: 42, endLineNumber: 50 }, options: { isWholeLine: true } },
  ]);
  reveal.reveal({ line: 10_000_000, column: 100 });
  expect(target.position()).toEqual({ lineNumber: 50, column: 8 });
  expect(target.clears()).toBe(1);
  jest.advanceTimersByTime(1500);
  expect(target.clears()).toBe(2);
  reveal.clear();
});

test("a hidden editor centers when laid out after the highlight expires", () => {
  jest.useFakeTimers();
  const target = editorTarget(0);
  const reveal = new LineReveal(target.target);
  reveal.reveal({ line: 42 });
  jest.advanceTimersByTime(1500);
  expect(target.clears()).toBe(1);
  expect(target.listening()).toBe(true);
  target.layout(0);
  expect(target.centers).toHaveLength(1);
  target.layout(640);
  expect(target.centers).toEqual([
    [42, 1],
    [42, 1],
  ]);
  expect(target.listening()).toBe(false);
  reveal.clear();
});

test("a new reveal or load/disposal cancels the old layout listener", () => {
  jest.useFakeTimers();
  const target = editorTarget(0);
  const reveal = new LineReveal(target.target);
  reveal.reveal({ line: 42 });
  reveal.reveal({ line: 3 });
  target.layout(640);
  expect(target.centers).toEqual([
    [42, 1],
    [3, 1],
    [3, 1],
  ]);
  reveal.reveal({ line: 4 });
  reveal.clear();
  target.layout(640);
  expect(target.centers).toHaveLength(4);
  expect(target.listening()).toBe(false);
});
