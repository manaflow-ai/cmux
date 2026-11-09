// l10n-allow-file: test fixtures.
// The Review queue's keys. `a` accepts the selected row and moves on, and acts only on the row the
// person chose: a refresh that hides it leaves `a` waiting. A comment whose send fails is never lost:
// the person may open another row's comment while the first send is in flight, and `r` on the first
// row still gives its words back with the same prompt id, so acpmux delivers it once. A draft
// stays with its row too, sent or not.
import { afterEach, expect, test } from "bun:test";
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { session } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSessionEntry } from "../sessionList";
import { ReviewScreen } from "./ReviewScreen";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "HTMLElement", "Element", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"];
let dom: JSDOM | null = null;
let root: Root | null = null;

const NOW = Date.parse("2026-11-08T12:00:00Z");
const chat = (name: string, activityAt: number) =>
  session({
    sessionId: `review-${name}`,
    title: `Change ${name}`,
    worktree: `/work/${name}`,
    branch: `lane/${name}`,
    activityAt,
  });
const sessions = ["a", "b"].map((name, at) => chat(name, NOW - (at + 1) * 60_000));
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

type Actions = Partial<Pick<ComponentProps<typeof ReviewScreen>, "readDiff" | "accept" | "send">>;

function mount(chats: AcpmuxSessionEntry[], actions: Actions = {}) {
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
  const window = dom.window;
  const doc = window.document;
  const done = async () => undefined;
  root = createRoot(doc.getElementById("root")!);
  const render = (next: AcpmuxSessionEntry[]) =>
    act(() =>
      root!.render(
        <ReviewScreen
          sessions={next}
          readDiff={actions.readDiff ?? readDiff}
          openDiff={done}
          accept={actions.accept ?? done}
          send={actions.send ?? done}
          now={NOW}
        />,
      ),
    );
  render(chats);
  const list = () => doc.querySelector<HTMLElement>('[role="listbox"]')!;
  const key = (target: Element, name: string) =>
    act(() => {
      target.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });
  const type = (text: string) => {
    const field = doc.querySelector<HTMLTextAreaElement>("textarea")!;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!;
    act(() => {
      setter.call(field, text);
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    return field;
  };
  return { doc, list, key, type, render };
}

test("`a` accepts the selected row and moves on to the next", async () => {
  const accepted: string[] = [];
  const view = mount(
    ["a", "b", "c"].map((name, at) => chat(name, NOW - (at + 1) * 60_000)),
    {
      accept: async (sessionId) => void accepted.push(sessionId),
    },
  );
  await flush();
  expect(view.doc.querySelectorAll('[role="option"]').length).toBe(3);
  view.key(view.list(), "a");
  view.key(view.list(), "a");
  expect(accepted).toEqual(["review-a", "review-b"]);
});

test("a refresh that hides the selected row leaves `a` waiting until the person moves", async () => {
  const accepted: string[] = [];
  const reads = new Map<string, number>();
  const view = mount(
    ["a", "b", "c"].map((name, at) => chat(name, NOW - (at + 1) * 60_000)),
    {
      accept: async (sessionId) => void accepted.push(sessionId),
      // A folder's second read never answers: its row and every row under it wait for it.
      readDiff: (cwd) => {
        const count = (reads.get(cwd) ?? 0) + 1;
        reads.set(cwd, count);
        return count > 1 ? new Promise(() => {}) : readDiff();
      },
    },
  );
  await flush();
  view.key(view.list(), "j");
  view.key(view.list(), "j");

  // B's chat does something, so B is read again; C (selected) hides under it.
  view.render([chat("a", NOW - 60_000), chat("b", NOW - 90_000), chat("c", NOW - 180_000)]);
  await flush();
  expect(view.doc.querySelectorAll('[role="option"]').length).toBe(1);
  view.key(view.list(), "a");
  expect(accepted).toEqual([]);

  // Moving picks a row again, and `a` accepts the one the person now sees selected.
  view.key(view.list(), "j");
  view.key(view.list(), "a");
  expect(accepted).toEqual(["review-a"]);
});

test("a failed send keeps its words and prompt id while another row's comment is open", async () => {
  const sent: { sessionId: string; text: string; promptId: string; fail(): void }[] = [];
  const send = (sessionId: string, text: string, _tag: string, promptId: string) =>
    new Promise((_resolve, reject) => sent.push({ sessionId, text, promptId, fail: () => reject(new Error("down")) }));
  const { doc, list: listbox, key, type } = mount(sessions, { send });
  await flush();
  const list = listbox();
  expect(doc.querySelectorAll('[role="option"]').length).toBe(2);

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

test("a comment not sent yet stays with its row when the person opens another row's comment", async () => {
  const { doc, list, key, type } = mount(sessions);
  await flush();
  key(list(), "r");
  type("half a thought");
  // Back to the list without sending, on to B, and a comment there.
  key(list(), "j");
  key(list(), "r");
  type("rename the flag");
  key(list(), "k");
  key(list(), "r");
  expect(doc.querySelector<HTMLTextAreaElement>("textarea")!.value).toBe("half a thought");
  key(list(), "j");
  key(list(), "r");
  expect(doc.querySelector<HTMLTextAreaElement>("textarea")!.value).toBe("rename the flag");
});

test("a send that fails late never overwrites a newer draft on its row", async () => {
  const sent: { fail(): void }[] = [];
  const send = () => new Promise((_resolve, reject) => sent.push({ fail: () => reject(new Error("down")) }));
  // A's folder gains a line after its first read, so its row comes back with a new change.
  const reads = new Map<string, number>();
  const grow = async (cwd: string) => {
    const count = (reads.get(cwd) ?? 0) + 1;
    reads.set(cwd, count);
    const diff = await readDiff();
    return cwd === "/work/a" && count > 1 ? { ...diff, additions: 3, files: [{ ...diff.files[0]!, additions: 3 }] } : diff;
  };
  const view = mount(sessions, { send, readDiff: grow });
  await flush();
  view.key(view.list(), "r");
  view.key(view.type("first words"), "Enter");
  await flush();

  // A's chat does more: its row is back, the person writes again there, then opens B's comment.
  view.render([chat("a", NOW - 10_000), chat("b", NOW - 120_000)]);
  await flush();
  view.key(view.list(), "k");
  view.key(view.list(), "r");
  view.type("second thoughts");
  view.key(view.list(), "j");
  view.key(view.list(), "r");

  // The first send fails now: A keeps the newer words.
  await act(async () => sent[0]!.fail());
  await flush();
  view.key(view.list(), "k");
  view.key(view.list(), "r");
  expect(view.doc.querySelector<HTMLTextAreaElement>("textarea")!.value).toBe("second thoughts");
});
