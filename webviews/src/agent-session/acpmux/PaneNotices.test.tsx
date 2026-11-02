// The app's notices about the chat's agent service (paneNoticeStore.ts, AgentPaneNotice.swift): the
// page draws them as cards in the notice slot above the composer, in the flow. A native label laid
// over the page floated over the transcript's first message (Leo, 2026-11-01).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { PaneNotices } from "./PaneNotices";
import { paneNotices, readPaneNotices, setPaneNotices } from "./paneNoticeStore";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setPaneNotices([]);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const OTHER = "This chat runs on another cmux install's agent service. Approve its requests in that app.";

test("malformed rows are left out; none is an empty list", () => {
  expect(readPaneNotices(null)).toEqual([]);
  expect(
    readPaneNotices([
      { id: "otherInstall", title: OTHER },
      { id: "remoteApprovals", title: "Remote approvals are off", detail: "Restart it", button: "Restart", enabled: false },
      { id: "x" },
      null,
    ]),
  ).toEqual([
    { id: "otherInstall", title: OTHER },
    { id: "remoteApprovals", title: "Remote approvals are off", detail: "Restart it", button: "Restart", enabled: false },
  ]);
});

test("the notice is a card in the slot's flow, and its button goes back to the app", async () => {
  const container = installDom();
  const clicks: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <NoticeSlot>
        <PaneNotices onAction={(id) => clicks.push(id)} />
      </NoticeSlot>,
    );
  });
  expect(container.innerHTML).toBe("");

  await act(async () =>
    setPaneNotices([
      { id: "otherInstall", title: OTHER },
      { id: "remoteApprovals", title: "Remote approvals are off", detail: "Restart it", button: "Restart" },
    ]),
  );
  const cards = [...container.querySelectorAll<HTMLElement>("[data-pane-notice]")];
  expect(cards.map((card) => card.dataset.paneNotice)).toEqual(["otherInstall", "remoteApprovals"]);
  // The notice slot's neutral card, in the flow above the composer, with a card behind its text.
  for (const card of cards) {
    expect(card.classList.contains("acpmux-host-error")).toBe(true);
    expect(card.classList.contains("acpmux-harness-notice")).toBe(true);
    expect(card.querySelector(".acpmux-host-error-card")).not.toBeNull();
  }
  expect(cards[0]!.textContent).toBe(OTHER);
  expect(cards[0]!.querySelector("button")).toBeNull();
  expect(cards[1]!.querySelector(".acpmux-host-error-hint")?.textContent).toBe("Restart it");
  const button = cards[1]!.querySelector("button")!;
  await act(async () => button.click());
  expect(clicks).toEqual(["remoteApprovals"]);

  // Off while the app runs it.
  await act(async () =>
    setPaneNotices([{ id: "remoteApprovals", title: "Remote approvals are off", button: "Restart", enabled: false }]),
  );
  expect(container.querySelector("button")?.disabled).toBe(true);

  await act(async () => setPaneNotices([]));
  expect(paneNotices()).toEqual([]);
  expect(container.innerHTML).toBe("");
});
