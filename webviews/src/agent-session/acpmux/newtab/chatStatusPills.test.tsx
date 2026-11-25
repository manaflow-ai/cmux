import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { resetSettledChatsForTests } from "./settledCache";
import { AllChatsList, type ActiveChat } from "./AllChatsList";
import { CHAT_LIST_STATUS_PILLS_KEY, setChatDisplay } from "../chatDisplay";
import { settleReact } from "../../../../test/support/domTeardown";

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

afterEach(async () => {
  act(() => root?.unmount());
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

// Status Pills in All Chats (Taste Board #19, agentPane.display.chatListStatusPills).
const active: ActiveChat[] = [
  { id: "run", title: "Running chat", harness: "claude", state: "running", label: "Running" },
  { id: "ask", title: "Asking chat", harness: "codex", state: "input", label: "Needs input" },
  { id: "new", title: "Finished chat", harness: "claude", state: "unread", label: "Unread" },
  { id: "bad", title: "Failed chat", harness: "claude", state: "failed", label: "Failed" },
  { id: "lost", title: "Lost chat", harness: "codex", state: "error", label: "Disconnected" },
];
const leads: ActiveChat[] = [
  { id: "lead", title: "coordinator", harness: "claude", state: "running", label: "4 reporting" },
  { id: "quiet", title: "area-owner", harness: "claude", state: "idle", label: "2 reporting" },
];
const indexed = { key: "claude:old", harness: "claude", title: "Old chat", updatedAt: 1 };

async function render() {
  await act(async () =>
    root!.render(
      <AllChatsList
        load={async () => ({ chats: [indexed], ready: true })}
        onOpen={() => {}}
        active={active}
        leads={leads}
        onOpenActive={() => {}}
        now={0}
      />,
    ),
  );
}

const rowOf = (title: string) =>
  [...container.querySelectorAll(".nt-all-row")].find(
    (row) => row.querySelector(".nt-all-title")?.textContent === title,
  );

test("off (the default), the rows are as before: plain state labels and no pill", async () => {
  setChatDisplay({});
  await render();
  expect(container.querySelector(".nt-all-pill")).toBeNull();
  expect(rowOf("Running chat")?.querySelector(".nt-all-state")?.textContent).toBe("Running");
  expect(rowOf("coordinator")?.querySelector(".nt-all-state")?.textContent).toBe("4 reporting");
});

test("on, each live chat that is not idle ends with its status pill; idle and indexed rows show none", async () => {
  setChatDisplay({ [CHAT_LIST_STATUS_PILLS_KEY]: true });
  try {
    await render();
    const pill = (title: string) => rowOf(title)?.querySelector(".nt-all-pill");
    expect(
      ["Running chat", "Asking chat", "Finished chat", "Failed chat", "Lost chat"].map((t) => pill(t)?.textContent),
    ).toEqual(["Running", "Needs you", "Done", "Failed", "Failed"]);
    expect(pill("Lost chat")?.getAttribute("data-tone")).toBe("failed");
    // The pill stands in for a live chat's state label.
    expect(rowOf("Running chat")?.querySelector(".nt-all-state")).toBeNull();
    // A leader keeps its count, the pill after it.
    expect(rowOf("coordinator")?.querySelector(".nt-all-state")?.textContent).toBe("4 reporting");
    expect(pill("coordinator")?.textContent).toBe("Running");
    expect(pill("area-owner") ?? null).toBeNull();
    expect(rowOf("area-owner")?.querySelector(".nt-all-state")?.textContent).toBe("2 reporting");
    await act(async () => {});
    expect(pill("Old chat") ?? null).toBeNull();
    expect(container.querySelectorAll(".nt-all-pill")).toHaveLength(6);
  } finally {
    setChatDisplay({});
  }
});
