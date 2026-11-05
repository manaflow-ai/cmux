import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { resetSettledChatsForTests } from "./settledCache";
import { AllChatsList, type ActiveChat } from "./AllChatsList";

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

const leads: ActiveChat[] = [
  { id: "owner", title: "acpmux-owner", harness: "claude", state: "running", label: "13 reporting" },
  { id: "coord", title: "claude-sr2-coord", harness: "claude", state: "idle", label: "4 reporting" },
];

test("New Tab lists every leader once under Leads, and a press opens that chat", async () => {
  const opened: string[] = [];
  await act(async () =>
    root!.render(
      <AllChatsList
        load={async () => ({ chats: [], ready: true })}
        onOpen={() => {}}
        leads={leads}
        onOpenActive={(id) => opened.push(id)}
        now={0}
      />,
    ),
  );
  const list = container.querySelector(".nt-all-leads");
  expect(list?.getAttribute("aria-label")).toBe("Leads");
  expect(list?.querySelector(".nt-all-leads-head")?.textContent).toBe("Leads2");
  const rows = [...(list?.querySelectorAll(".nt-all-row") ?? [])];
  expect(rows.map((r) => r.querySelector(".nt-all-title")?.textContent)).toEqual(["acpmux-owner", "claude-sr2-coord"]);
  expect(rows.map((r) => r.querySelector(".nt-all-state")?.textContent)).toEqual(["13 reporting", "4 reporting"]);
  const press = new dom!.window.MouseEvent("mousedown", { bubbles: true, button: 0 });
  await act(async () => void rows[1]!.dispatchEvent(press));
  expect(opened).toEqual(["coord"]);
});

test("with no leaders there is no Leads list", async () => {
  await act(async () =>
    root!.render(<AllChatsList load={async () => ({ chats: [], ready: true })} onOpen={() => {}} now={0} />),
  );
  expect(container.querySelector(".nt-all-leads")).toBeNull();
});
