// Returning to existing work must explain a refused Open Chat request and let the user retry.
// The same current action is used by New Tab and History; other rows may be clicked meanwhile.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useChatOpenFeedback } from "./AllChatsList";
import { newTabScreenActions } from "./screenActions";

const scope = globalThis as Record<string, unknown>;
const names = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
let saved: Array<readonly [string, boolean, unknown]>;
let dom: JSDOM;
let root: Root;
let host: HTMLElement;

beforeEach(() => {
  saved = names.map((key) => [key, key in scope, scope[key]] as const);
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  for (const [name, had, value] of saved) {
    if (had) scope[name] = value;
    else delete scope[name];
  }
  dom.window.close();
});

type Open = (key: string) => void | Promise<unknown>;
type Bring = (keys: string[]) => void | Promise<unknown>;

function Probe({ onOpen, onBring }: { onOpen: Open; onBring?: Bring }) {
  const { open, bring, opening, failure } = useChatOpenFeedback(onOpen, onBring);
  return (
    <div>
      <button data-open="a" type="button" onClick={() => open("a")}>Open A</button>
      <button data-open="b" type="button" onClick={() => open("b")}>Open B</button>
      <button data-bring type="button" onClick={() => bring(["a", "b"])}>Bring</button>
      <output data-opening={opening ?? ""} data-failed={failure?.key ?? ""}>
        {failure?.message ?? ""}
      </output>
    </div>
  );
}

const button = (selector: string) => host.querySelector<HTMLButtonElement>(selector)!;
const result = () => host.querySelector<HTMLOutputElement>("output")!;

test("a refused chat open names the failure, releases the pending click, and retries the same key", async () => {
  const calls: string[] = [];
  let rejectFirst!: (reason: Error) => void;
  let first = true;
  const onOpen: Open = (key) => {
    calls.push(key);
    if (first) {
      first = false;
      return new Promise<void>((_resolve, reject) => { rejectFirst = reject; });
    }
    return Promise.resolve();
  };
  await act(async () => root.render(<Probe onOpen={onOpen} />));
  await act(async () => { button('[data-open="a"]').click(); button('[data-open="a"]').click(); });
  expect(calls).toEqual(["a"]);
  expect(result().dataset.opening).toBe("a");
  await act(async () => rejectFirst(new Error("This machine disconnected")));
  expect(result().textContent).toContain("This machine disconnected");
  expect(result().dataset.failed).toBe("a");

  await act(async () => button('[data-open="a"]').click());
  expect(calls).toEqual(["a", "a"]);
  expect(result().textContent).toBe("");
});

test("a late failure from an older chat never replaces the newer click's state", async () => {
  let rejectA!: (reason: Error) => void;
  const calls: string[] = [];
  const onOpen: Open = (key) => {
    calls.push(key);
    return key === "a" ? new Promise<void>((_resolve, reject) => { rejectA = reject; }) : Promise.resolve();
  };
  await act(async () => root.render(<Probe onOpen={onOpen} />));
  await act(async () => button('[data-open="a"]').click());
  await act(async () => button('[data-open="b"]').click());
  await act(async () => rejectA(new Error("Old A failed")));
  expect(calls).toEqual(["a", "b"]);
  expect(result().textContent).toBe("");
  expect(result().dataset.opening).toBe("");
});

test("a bulk History open reports a rejected host action without repeating successful opens", async () => {
  await act(async () =>
    root.render(<Probe onOpen={() => {}} onBring={() => Promise.reject(new Error("Could not open B"))} />),
  );
  await act(async () => button("[data-bring]").click());
  expect(result().textContent).toContain("Could not open B");
  expect(result().dataset.failed).toBe("");
});

test("the New Tab host propagates chat-open refusal to the presenting page", async () => {
  const actions = newTabScreenActions({
    callNative: (method) =>
      method === "chats.open" ? Promise.reject(new Error("Machine unavailable")) : Promise.resolve(undefined),
    leave: () => {},
    selectSession: () => {},
    showAllChats: () => {},
    runShell: () => {},
  });
  await expect(actions.onOpenChat?.("claude:test")).rejects.toThrow("Machine unavailable");
});
