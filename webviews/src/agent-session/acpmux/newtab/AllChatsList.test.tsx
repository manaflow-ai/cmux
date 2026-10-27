import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { resetSettledChatsForTests } from "./settledCache";
import { useChatPages, type AllChatsPage, type LoadChatsPage } from "./AllChatsList";

type Request = {
  params: Parameters<LoadChatsPage>[0];
  resolve(page: AllChatsPage | undefined): void;
  reject(error: unknown): void;
};

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "localStorage", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
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
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  resetSettledChatsForTests();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function Probe({ load }: { load: LoadChatsPage }) {
  const { state, fetchPage } = useChatPages(load);
  return (
    <div>
      <output data-loaded={state.loaded} data-cursor={state.nextCursor ?? ""} data-failed={state.failedCursor ?? ""} />
      <button
        type="button"
        data-more
        onClick={() => state.nextCursor && fetchPage(state.query, state.nextCursor)}
      />
    </div>
  );
}

function queuedLoad(requests: Request[]): LoadChatsPage {
  return (params) =>
    new Promise<AllChatsPage | undefined>((resolve, reject) => {
      requests.push({ params, resolve, reject });
    });
}

async function render(load: LoadChatsPage) {
  await act(async () => root!.render(<Probe load={load} />));
}

const page = (nextCursor?: string): AllChatsPage => ({
  chats: [{ key: "claude:one", harness: "claude", title: "One", updatedAt: 1 }],
  ...(nextCursor ? { nextCursor } : {}),
});

test("a failed later page keeps its cursor and can be retried while its loader stays visible", async () => {
  const requests: Request[] = [];
  await render(queuedLoad(requests));
  expect(requests).toHaveLength(1);
  await act(async () => requests[0]!.resolve(page("page-2")));
  expect(container.querySelector("output")?.dataset.cursor).toBe("page-2");

  await act(async () => container.querySelector<HTMLButtonElement>("[data-more]")!.click());
  expect(requests).toHaveLength(2);
  await act(async () => requests[1]!.reject(new Error("daemon unavailable")));
  const failed = container.querySelector("output")!;
  expect(failed.dataset.cursor).toBe("page-2");
  expect(failed.dataset.failed).toBe("page-2");

  await act(async () => container.querySelector<HTMLButtonElement>("[data-more]")!.click());
  expect(requests).toHaveLength(3);
  expect(requests[2]!.params.cursor).toBe("page-2");
  await act(async () => requests[2]!.resolve({ chats: [], ready: true }));
  expect(container.querySelector("output")?.dataset.failed).toBe("");
});
