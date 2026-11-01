// A Codex skill goes to Codex as `/$name` (slashCommands.ts withSkillDollars), but the person typed
// `/name`: a sent prompt reads `/name` again in its bubble, its Copy, its right-click menu's text,
// its editor and the queue, while Retry and the stored text keep what was sent (Lucas 2026-11-02).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
const copied: string[] = [];

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
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

const SENT = "hello lets use /$emil-design-vocabulary to figure out what the animations are";
const SHOWN = "hello lets use /emil-design-vocabulary to figure out what the animations are";

const rows = [
  { id: "user-1", version: 1, at: 0, kind: "user", seq: 1, text: "Start" },
  { id: "assistant-2", version: 1, at: 0, kind: "assistant", text: "Done." },
  { id: "summary-3", version: 1, at: 0, kind: "turnSummary", seq: 3 },
  { id: "user-4", version: 1, at: 0, kind: "user", seq: 4, text: SENT },
  { id: "assistant-5", version: 1, at: 0, kind: "assistant", text: "Added." },
  { id: "summary-6", version: 1, at: 0, kind: "turnSummary", seq: 6 },
] as const;

const button = (label: string) =>
  [...host.querySelectorAll("button")].find((element) => element.getAttribute("aria-label") === label);

test("the bubble, its Copy and its editor read `/name`; Edit sends `/$name`, Retry the prompt as sent", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { editableTurns } = await import("../src/agent-session/acpmux/conversation/editPrompt");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  const sent: string[] = [];
  const retried: string[] = [];
  const actions = {
    edit: {
      seqs: editableTurns([...rows], "codex"),
      send: async (_rowId: string, _seq: number, text: string) => {
        sent.push(text);
        return true;
      },
    },
    retry: (_rowId: string, prompt: string) => void retried.push(prompt),
  };
  root = createRoot(host);
  act(() =>
    root!.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={rows[3]} text={SENT} />
      </TurnActionsContext.Provider>,
    ),
  );
  const bubble = host.querySelector(".cv-user__bubble")!;
  expect(bubble.textContent).toContain("/emil-design-vocabulary");
  expect(bubble.textContent).not.toContain("/$");

  await act(async () => button("Copy")!.click());
  expect(copied).toEqual([SHOWN]);

  act(() => button("Retry")!.click());
  expect(retried).toEqual([SENT]);

  act(() => button("Edit")!.click());
  const editor = host.querySelector("textarea")!;
  expect(editor.value).toBe(SHOWN);
  await act(async () => button("Send")!.click());
  expect(sent).toEqual([SENT]);
});

test("the right-click menu copies the prompt as the bubble reads it", async () => {
  const { messageMenuTarget } = await import("../src/agent-session/acpmux/conversation/messageMenu");
  const { noChat } = await import("../src/gallery/fixtures/acpmux");
  const snapshot = noChat([], { rows: [...rows] as never });
  expect(messageMenuTarget(snapshot, "user-4")?.text).toBe(SHOWN);
});

test("the queue shows `/name`, and a queued prompt edited there keeps `/$name`", async () => {
  const { shownText } = await import("../src/agent-session/acpmux/ComposerQueue");
  const t = ((key: string) => key) as never;
  expect(shownText({ id: "q", prompt: SENT }, t)).toBe(SHOWN);
});

test("prompt history brings a prompt back as typed", async () => {
  const { usePromptHistory } = await import("../src/agent-session/acpmux/composer/promptHistory");
  const { createRoot } = await import("react-dom/client");
  let recalled: string | null | undefined;
  function Probe() {
    const history = usePromptHistory([...rows] as never);
    recalled = history.step(-1, "");
    return null;
  }
  const probe = createRoot(host.ownerDocument.createElement("div"));
  act(() => probe.render(<Probe />));
  act(() => probe.unmount());
  expect(recalled).toBe(SHOWN);
});
