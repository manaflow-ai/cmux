// l10n-allow-file: test fixtures.
// A comment whose send fails is never lost: the person may open another row's comment while the
// first send is in flight, and `r` on the first row still gives its words back with the same prompt
// id, so acpmux delivers it once.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { session } from "../../../gallery/fixtures/acpmux";
import { ReviewScreen } from "./ReviewScreen";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "HTMLElement", "Element", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"];
let dom: JSDOM | null = null;
let root: Root | null = null;

const NOW = Date.parse("2026-11-08T12:00:00Z");
const sessions = ["a", "b"].map((name, at) =>
  session({
    sessionId: `review-${name}`,
    title: `Change ${name}`,
    worktree: `/work/${name}`,
    branch: `lane/${name}`,
    activityAt: NOW - (at + 1) * 60_000,
  }),
);
const readDiff = async () => ({
  scope: "branch",
  head: "1111111111111111111111111111111111111111",
  files: [{ path: "src/a.ts", additions: 2, deletions: 1, status: "modified" }],
  additions: 2,
  deletions: 1,
  total_files: 1,
});

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = null;
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

async function flush() {
  await act(async () => {
    for (let turn = 0; turn < 5; turn++) await Promise.resolve();
  });
}

test("a failed send keeps its words and prompt id while another row's comment is open", async () => {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const doc = dom.window.document;
  const sent: { sessionId: string; text: string; promptId: string; fail(): void }[] = [];
  const send = (sessionId: string, text: string, _tag: string, promptId: string) =>
    new Promise((_resolve, reject) => sent.push({ sessionId, text, promptId, fail: () => reject(new Error("down")) }));
  const done = async () => undefined;
  root = createRoot(doc.getElementById("root")!);
  act(() =>
    root!.render(
      <ReviewScreen sessions={sessions} readDiff={readDiff} openDiff={done} accept={done} send={send} now={NOW} />,
    ),
  );
  await flush();
  const list = doc.querySelector<HTMLElement>('[role="listbox"]')!;
  expect(doc.querySelectorAll('[role="option"]').length).toBe(2);

  const key = (target: Element, name: string) =>
    act(() => {
      target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });
  const type = (text: string) => {
    const field = doc.querySelector<HTMLTextAreaElement>("textarea")!;
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    act(() => {
      setter.call(field, text);
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    return field;
  };

  // Comment A goes out; while it is in flight the person opens a comment on B.
  key(list, "r");
  key(type("please add a test"), "Enter");
  expect(sent).toHaveLength(1);
  key(list, "j");
  key(list, "r");
  type("rename the flag");

  // A fails: B's open comment stays as it is.
  await act(async () => sent[0]!.fail());
  await flush();
  expect(doc.querySelector<HTMLTextAreaElement>("textarea")!.value).toBe("rename the flag");

  // Back on A, `r` gives its words back, and resending them reuses the prompt id.
  key(doc.querySelector("textarea")!, "Escape");
  key(list, "k");
  key(list, "r");
  const field = doc.querySelector<HTMLTextAreaElement>("textarea")!;
  expect(field.value).toBe("please add a test");
  key(field, "Enter");
  expect(sent).toHaveLength(2);
  expect(sent[1]!.sessionId).toBe(sent[0]!.sessionId);
  expect(sent[1]!.promptId).toBe(sent[0]!.promptId);
});
