import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { resetSettledChatsForTests } from "./settledCache";
import { AllChatsList } from "./AllChatsList";
import { SEARCH_SETTLE_MS, useChatPages, type AllChatsPage, type LoadChatsPage } from "./allChatsListModel";
import { settleReact } from "../../../../test/support/domTeardown";

// All chats search asks the daemon once per settled query, not once per keystroke: each read
// ranks every chat, so a read per key made typing cost keys x chats (Leo, 2026-11-04: "never ...
// acceptable ... linear time growth degradation").

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  resetSettledChatsForTests();
  jest.useFakeTimers();
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  jest.useRealTimers();
  root = undefined;
  resetSettledChatsForTests();
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

type Request = { params: Parameters<LoadChatsPage>[0]; resolve(page: AllChatsPage | undefined): void };

const row = (key: string, title: string) => ({ key, harness: "claude", title, updatedAt: 1 });

async function mount(requests: Request[]) {
  const load: LoadChatsPage = (params) =>
    new Promise((resolve) => {
      requests.push({ params, resolve });
    });
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} now={0} />));
  await act(async () => requests[0]!.resolve({ chats: [row("claude:a", "A")], ready: true }));
}

function input() {
  return container.querySelector<HTMLInputElement>(".nt-all-search input")!;
}

async function type(text: string) {
  const field = input();
  const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

const settle = () => act(async () => void jest.advanceTimersByTime(SEARCH_SETTLE_MS));

const queries = (requests: Request[]) => requests.slice(1).map((request) => request.params.query ?? "");

test("typing a word reads one page for the word, not one per key; the field shows each key at once", async () => {
  const requests: Request[] = [];
  await mount(requests);
  for (const end of [1, 2, 3, 4, 5, 6]) {
    await type("deploy".slice(0, end));
    expect(input().value).toBe("deploy".slice(0, end));
  }
  expect(queries(requests)).toEqual([]);
  await settle();
  expect(queries(requests)).toEqual(["deploy"]);
});

function Probe({ load }: { load: LoadChatsPage }) {
  const { state, search } = useChatPages(load);
  return (
    <div>
      <output data-keys={state.rows.map((r) => r.key).join(",")} data-query={state.query} />
      <input className="probe" aria-label="Search" onChange={(event) => search(event.currentTarget.value)} />
    </div>
  );
}

test("a reply for a query typed past is dropped, and clearing the field reads the list at once", async () => {
  const requests: Request[] = [];
  const load: LoadChatsPage = (params) =>
    new Promise((resolve) => {
      requests.push({ params, resolve });
    });
  await act(async () => root!.render(<Probe load={load} />));
  await act(async () => requests[0]!.resolve({ chats: [row("claude:a", "A")], ready: true }));
  const field = container.querySelector<HTMLInputElement>("input.probe")!;
  const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
  const typeInto = (text: string) =>
    act(async () => {
      setValue.call(field, text);
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
  const keys = () => container.querySelector("output")!.dataset.keys;
  await typeInto("dep");
  await settle();
  expect(queries(requests)).toEqual(["dep"]);
  await typeInto("deplo");
  expect(container.querySelector("output")!.dataset.query).toBe("deplo");
  // The reply for "dep" lands after "deplo" was typed: the list does not take it.
  await act(async () => requests[1]!.resolve({ chats: [row("claude:old", "Old reply")], ready: true }));
  expect(keys()).toBe("claude:a");
  await settle();
  expect(queries(requests)).toEqual(["dep", "deplo"]);
  await act(async () => requests[2]!.resolve({ chats: [row("claude:new", "New reply")], ready: true }));
  expect(keys()).toBe("claude:new");
  await typeInto("");
  expect(queries(requests)).toEqual(["dep", "deplo", ""]);
});
