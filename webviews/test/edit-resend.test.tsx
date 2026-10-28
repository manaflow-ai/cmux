// Edit and resend a past message (cx-ncc.60, Claude parity): a prompt shows Edit under its bubble on
// hover; Edit opens it in place, Send forks the chat through the turn before it and sends the edited
// text there, Escape or Cancel puts the bubble back. Edit shows only where the chat can fork there.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const rows = [
  { id: "user-1", version: 1, at: 0, kind: "user", seq: 1, text: "Add retry to the uploader" },
  { id: "assistant-2", version: 1, at: 0, kind: "assistant", text: "Done." },
  { id: "summary-3", version: 1, at: 0, kind: "turnSummary", seq: 3 },
  { id: "user-4", version: 1, at: 0, kind: "user", seq: 4, text: "Now cover it with a test" },
  { id: "assistant-5", version: 1, at: 0, kind: "assistant", text: "Added." },
  { id: "summary-6", version: 1, at: 0, kind: "turnSummary", seq: 6 },
];

const button = (label: string) =>
  [...host.querySelectorAll("button")].find((element) => element.getAttribute("aria-label") === label);

test("a prompt edited in place forks the chat through the turn before it and sends the edited text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { editableTurns } = await import("../src/agent-session/acpmux/conversation/editPrompt");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  const sent: [string, number, string][] = [];
  // The first resend is refused (acpmux would not fork there): the draft stays open.
  const accept = [false, true];
  const seqs = editableTurns(rows, "claude");
  const send = async (rowId: string, seq: number, text: string) => {
    sent.push([rowId, seq, text]);
    return accept.shift() ?? true;
  };
  const actions = { edit: { seqs, send } };
  const draw = (row: (typeof rows)[number]) =>
    act(() =>
      root!.render(
        <TurnActionsContext.Provider value={actions}>
          <UserBubble row={row} text={row.text ?? ""} />
        </TurnActionsContext.Provider>,
      ),
    );

  root = createRoot(host);
  // The first prompt has no turn before it to fork through: its row offers Copy (Claude Code desktop's
  // row, GUI push 2026-10-20), but no Edit and no Fork.
  draw(rows[0]!);
  expect(button("Copy")).toBeDefined();
  expect(button("Edit")).toBeUndefined();
  expect(button("Fork from here")).toBeUndefined();

  draw(rows[3]!);
  act(() => button("Edit")!.click());
  const editor = host.querySelector("textarea")!;
  expect(editor.value).toBe("Now cover it with a test");
  act(() => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), "value")!.set!;
    set.call(editor, "Now cover it with two tests");
    editor.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await act(async () => button("Send")!.click());
  expect(sent).toEqual([["user-4", 3, "Now cover it with two tests"]]);
  expect(host.querySelector("textarea")?.value).toBe("Now cover it with two tests");
  await act(async () => button("Send")!.click());
  expect(sent.length).toBe(2);
  expect(host.querySelector("textarea")).toBeNull();

  // Escape puts the bubble back and sends nothing.
  act(() => button("Edit")!.click());
  act(() => {
    host
      .querySelector("textarea")!
      .dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(host.querySelector("textarea")).toBeNull();
  expect(sent.length).toBe(2);
});

test("Claude and Codex chats that can fork through an earlier turn offer Edit", async () => {
  const { editableTurns } = await import("../src/agent-session/acpmux/conversation/editPrompt");
  expect([...editableTurns(rows, "claude")]).toEqual([["user-4", 3]]);
  expect([...editableTurns(rows, "codex")]).toEqual([["user-4", 3]]);
  expect(editableTurns([...rows.slice(0, 3), { ...rows[3]!, steer: "waiting" }], "claude").size).toBe(0);
});
