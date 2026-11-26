import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { resetSettledChatsForTests } from "./settledCache";
import { AllChatsList } from "./AllChatsList";
import { SEARCH_SETTLE_MS, useChatPages, type AllChatsPage, type LoadChatsPage } from "./allChatsListModel";
import { settleReact } from "../../../../test/support/domTeardown";
import { LASTING_MS } from "../../../ui/lasting";

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

// A first read that fails is no one's decision (Leo, 2026-11-22: "vacuous decisions like that should be
// just done"): the list asks again on its own, shows no Try again, and says one quiet line only once the
// failure has lasted the house deadline (autoRetry.ts, lasting.ts LASTING_MS).
test("a failed first read is asked again on its own, with no button, and says one quiet line only once it lasts", async () => {
  const requests: Request[] = [];
  const load: LoadChatsPage = (params) =>
    new Promise((resolve) => {
      requests.push({ params, resolve });
    });
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} now={0} />));
  const failLatest = () => act(async () => requests.at(-1)!.resolve(undefined));
  const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));
  const quietLine = () => container.querySelector(".nt-chats-failed");

  await failLatest();
  expect(container.querySelector("button.nt-chats-retry")).toBeNull();
  expect(quietLine()).toBeNull();
  // The first ask again comes within a second (jittered), for the first page of the same query.
  await wait(1_000);
  expect(requests).toHaveLength(2);
  expect(requests[1]!.params.cursor).toBeUndefined();

  let elapsed = 1_000;
  while (elapsed < LASTING_MS) {
    await failLatest();
    expect(quietLine()).toBeNull();
    await wait(5_000);
    elapsed += 5_000;
  }
  await failLatest();
  const line = quietLine();
  expect(line?.textContent).toBeTruthy();
  expect(line?.querySelector("button")).toBeNull();
  const asked = requests.length;
  expect(asked).toBeGreaterThan(3);

  // It keeps asking (the jittered backoff tops out at 30 s, so a 30 s wait holds at least one ask) and
  // the first read that lands clears the line.
  await wait(30_000);
  expect(requests.length).toBeGreaterThan(asked);
  await act(async () => requests.at(-1)!.resolve({ chats: [row("claude:a", "A")], ready: true }));
  expect(quietLine()).toBeNull();
  // Nothing more is asked once it landed.
  const landed = requests.length;
  await wait(60_000);
  expect(requests.length).toBe(landed);
});
