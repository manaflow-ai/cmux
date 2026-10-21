// ↑ on an empty composer edits the chat's last prompt in place, as in Claude's apps (Leo, 2026-10-20;
// Debug Settings' "↑ edits the last prompt"): the prompt's own editor opens (UserBubble), and Esc
// there gives the keyboard back to the composer. Only the last prompt opens, and only where Edit
// shows (editableTurns): elsewhere ↑ keeps bringing back earlier prompts.
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

test("↑ on an empty composer opens the last prompt's editor, and Esc gives the keyboard back", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { editableTurns, lastEditablePrompt, openPromptEditor } =
    await import("../src/agent-session/acpmux/conversation/editPrompt");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  const seqs = editableTurns(rows, "claude");
  const actions = { edit: { seqs, send: async () => true } };
  root = createRoot(host);
  act(() =>
    root!.render(
      <TurnActionsContext.Provider value={actions}>
        {rows
          .filter((row) => row.kind === "user")
          .map((row) => (
            <UserBubble key={row.id} row={row} text={row.text ?? ""} />
          ))}
      </TurnActionsContext.Provider>,
    ),
  );
  expect(lastEditablePrompt(rows, seqs)).toBe("user-4");
  let back = 0;
  act(() => void expect(openPromptEditor(lastEditablePrompt(rows, seqs), () => back++)).toBe(true));
  const editor = host.querySelector("textarea")!;
  expect(editor.value).toBe("Now cover it with a test");
  expect(window.document.activeElement).toBe(editor);
  act(() => {
    editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(host.querySelector("textarea")).toBeNull();
  expect(back).toBe(1);
  // Opened from its Edit button, a cancel leaves the keyboard where it is.
  act(() => button("Edit")!.click());
  act(() => {
    host
      .querySelector("textarea")!
      .dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(back).toBe(1);
  act(() => root!.unmount());
  root = undefined;
  // Unmounted, nothing opens: ↑ then brings back earlier prompts instead.
  expect(openPromptEditor("user-4")).toBe(false);
});

test("only the chat's last prompt opens from ↑, and only when it edits", async () => {
  const { editableTurns, lastEditablePrompt } = await import("../src/agent-session/acpmux/conversation/editPrompt");
  const seqs = editableTurns(rows, "claude");
  // The first prompt has no turn before it: ↑ never opens an older prompt in its place.
  expect(lastEditablePrompt(rows.slice(0, 3), seqs)).toBeUndefined();
  // A queued prompt is the queue's (ComposerQueue.tsx), not the last sent one.
  const queued = [...rows, { id: "user-7", version: 1, at: 0, kind: "user", seq: 7, text: "Then ship", queued: "q" }];
  expect(lastEditablePrompt(queued, editableTurns(queued, "claude"))).toBe("user-4");
  // Other agents fork only at a chat's end, so ↑ edits nothing there.
  expect(lastEditablePrompt(rows, editableTurns(rows, "codex"))).toBeUndefined();
});
