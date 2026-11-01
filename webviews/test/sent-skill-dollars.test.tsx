// A Codex skill goes to Codex as `/$name` (slashCommands.ts withSkillDollars), but the person typed
// `/name`: a sent prompt reads `/name` again in its bubble, its Copy, its right-click menu's text,
// its editor and the queue, while Retry and the stored text keep what was sent (Lucas 2026-11-02).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "Element",
  "HTMLElement",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
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
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: FrameRequestCallback) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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

/// The chat's command list: Codex lists its skills as `$name`.
const COMMANDS = [
  { name: "init", description: "", source: "agent" as const },
  { name: "$emil-design-vocabulary", description: "Design words", source: "skill" as const },
  { name: "$emil-color", description: "Colour in CSS", source: "skill" as const },
];

const button = (label: string) =>
  [...host.querySelectorAll("button")].find((element) => element.getAttribute("aria-label") === label);

test("the bubble, its Copy and its editor read `/name`; Edit sends `/$name`, Retry the prompt as sent", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { editableTurns } = await import("../src/agent-session/acpmux/conversation/editPrompt");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  const { SkillWordsContext } = await import("../src/agent-session/acpmux/conversation/skillWords");
  const { skillCatalog } = await import("../src/agent-session/acpmux/slashCommands");
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
        <SkillWordsContext.Provider value={skillCatalog(COMMANDS)}>
          <UserBubble row={rows[3]} text={SENT} />
        </SkillWordsContext.Provider>
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
  // A skill added in the editor goes as `/$name` too.
  act(() => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), "value")!.set!;
    set.call(editor, `${SHOWN} with /emil-color`);
    editor.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await act(async () => button("Send")!.click());
  expect(sent).toEqual([`${SENT} with /$emil-color`]);
});

test("the right-click menu copies the prompt as the bubble reads it", async () => {
  const { messageMenuTarget } = await import("../src/agent-session/acpmux/conversation/messageMenu");
  const { noChat } = await import("../src/gallery/fixtures/acpmux");
  const snapshot = noChat([], { rows: [...rows] as never, commands: COMMANDS });
  expect(messageMenuTarget(snapshot, "user-4")?.text).toBe(SHOWN);
});

test("a queued prompt shows `/name`; edited and saved there, its skills go as `/$name`, a new one too", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  const edits: unknown[] = [];
  const box = host.ownerDocument.createElement("div");
  host.ownerDocument.body.append(box);
  const queue = createRoot(box);
  await act(async () =>
    queue.render(
      <ComposerQueue
        queue={[{ id: "q-1", prompt: SENT }]}
        chat="c"
        t={((key: string) => key) as never}
        commands={COMMANDS}
        onChange={async (id, edit) => {
          edits.push([id, edit]);
          return true;
        }}
        onRemove={async () => true}
      />,
    ),
  );
  const row = box.querySelector<HTMLElement>('[data-prompt-id="q-1"]')!;
  expect(row.textContent).toContain(SHOWN);
  row.focus();
  await act(async () => {
    row.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  const field = box.querySelector<HTMLTextAreaElement>('[data-prompt-id="q-1"] textarea')!;
  expect(field.value).toBe(SHOWN);
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    set.call(field, `${SHOWN} with /emil-color`);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(edits).toEqual([["q-1", { op: "update", text: `${SENT} with /$emil-color` }]]);
  await act(async () => queue.unmount());
  box.remove();
});

test("prompt history brings a prompt back as typed, reading prompts only as they are recalled", async () => {
  const { usePromptHistory } = await import("../src/agent-session/acpmux/composer/promptHistory");
  const { withoutSkillDollars } = await import("../src/agent-session/acpmux/slashCommands");
  const { createRoot } = await import("react-dom/client");
  let reads = 0;
  const shown = (sent: string) => {
    reads++;
    return withoutSkillDollars(sent, COMMANDS);
  };
  let history: ReturnType<typeof usePromptHistory> | undefined;
  function Probe({ list }: { list: readonly unknown[] }) {
    history = usePromptHistory(list as never, shown);
    return null;
  }
  const probe = createRoot(host.ownerDocument.createElement("div"));
  // New rows, as a streaming chat brings them: no prompt is read.
  act(() => probe.render(<Probe list={[...rows]} />));
  act(() =>
    probe.render(
      <Probe list={[...rows, { id: "assistant-7", version: 1, at: 0, kind: "assistant", text: "More." }]} />,
    ),
  );
  expect(reads).toBe(0);
  let recalled: string | null | undefined;
  act(() => {
    recalled = history!.step(-1, "");
  });
  expect(recalled).toBe(SHOWN);
  expect(history!.recalledRaw()).toBe(SENT);
  act(() => probe.unmount());
});
