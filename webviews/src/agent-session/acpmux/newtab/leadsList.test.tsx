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

test("a leader is shown once, with its machine and direct-report attention, without hiding a same-id local chat", async () => {
  const active: ActiveChat[] = [
    { id: "owner", peer: "huge-blue", title: "owner", state: "running", label: "Working" },
    { id: "owner", title: "local-owner", state: "running", label: "Working" },
    { id: "other", title: "other", state: "input", label: "Needs input" },
  ];
  await act(async () =>
    root!.render(
      <AllChatsList
        load={async () => ({ chats: [], ready: true })}
        onOpen={() => {}}
        leads={[{ ...leads[0]!, peer: "huge-blue", location: "huge-blue", needsInput: 2 }]}
        active={active}
        onOpenActive={() => {}}
        now={0}
      />,
    ),
  );
  expect(container.querySelectorAll(".nt-all-leads .nt-all-row")).toHaveLength(1);
  const lead = container.querySelector(".nt-all-leads .nt-all-row");
  expect(lead?.querySelector(".nt-all-project")?.textContent).toBe("huge-blue");
  expect(lead?.querySelector(".nt-all-state")?.textContent).toContain("Needs input (2)");
  expect(lead?.getAttribute("data-needs-input")).toBe("true");
  const activeRows = [...container.querySelectorAll('.nt-all-active:not(.nt-all-leads) .nt-all-title')];
  expect(activeRows.map((row) => row.textContent)).toEqual(["local-owner", "other"]);
});
