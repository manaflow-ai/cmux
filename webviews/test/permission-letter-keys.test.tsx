// l10n-allow-file: test fixture asks, commands and option names, not shipped UI.
// Approving a tool call is one obvious key (dealbreakers row D8): one person clicked about 600
// approvals in a day in another app, and approvals are where people quit. The permission card,
// the grouped permission panel and Needs you answer y (allow once), a (always allow) and n (deny),
// and the card's Return and Esc, while the ask is the prompt: nothing focused, focus on the card,
// or focus in an empty composer, where the keyboard usually sits (an answer hands it back there).
// A half-written prompt keeps every key: typing "yes" into a draft never answers anything.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM(
  `<!doctype html><div id=root></div>
  <div class="acpmux-composer-prompt"><div class="acpmux-md-root"><div id=editor contenteditable="true"></div></div></div>
  <textarea id=elsewhere></textarea>`,
  { url: "http://localhost/", pretendToBeVisual: true, virtualConsole: new VirtualConsole() },
);
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
const { permissionKeyAction } = await import("../src/agent-session/acpmux/permissions/prompt");
const { NeedsYouPanel } = await import("../src/agent-session/acpmux/needsYou/NeedsYou");
const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
type NeedsYouItem = import("../src/agent-session/acpmux/needsYou/model").NeedsYouItem;
type PermissionClientState = import("../src/agent-session/acpmux/permissions/protocol").PermissionClientState;

const doc = dom.window.document;
const editor = doc.getElementById("editor")!;
const field = doc.getElementById("elsewhere")!;
const host = doc.getElementById("root")!;
const draft = (text: string) => {
  editor.textContent = text;
};
afterEach(() => draft(""));

const options: AcpmuxPermission["options"] = [
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "always", name: "Always Allow", kind: "allow_always", allow: true },
  { id: "reject", name: "Reject", kind: "reject_once", allow: false },
];
const bash = (permissionId: string): AcpmuxPermission => ({
  permissionId,
  title: "Run npm test",
  kind: "execute",
  command: "npm test",
  pending: true,
  options,
});

const plain = { metaKey: false, ctrlKey: false, altKey: false, shiftKey: false };

test("y, a and n answer the card with nothing focused, and from an empty composer", () => {
  const card = doc.createElement("fieldset");
  const key = (name: string, target: Element, extra: { metaKey?: boolean } = {}) =>
    permissionKeyAction({ key: name, target, ...plain, ...extra }, card, false);
  expect(["y", "a", "n"].map((name) => key(name, doc.body))).toEqual(["allow_once", "allow_always", "deny"]);
  // Caps Lock types capitals without Shift: the same answer.
  expect(key("Y", doc.body)).toBe("allow_once");
  // The composer with nothing typed: the letters, Return, ⌘↩ and Esc are the card's.
  expect(["y", "a", "n", "Enter", "Escape"].map((name) => key(name, editor))).toEqual([
    "allow_once",
    "allow_always",
    "deny",
    "allow_once",
    "deny",
  ]);
  expect(key("Enter", editor, { metaKey: true })).toBe("allow_once");
  // A digit still types: a prompt may start "1." and the card's digits need the card or no focus.
  expect(key("1", editor)).toBeUndefined();
  // Any other field keeps its letters.
  expect(["y", "n", "a"].map((name) => key(name, field))).toEqual([undefined, undefined, undefined]);
  // With the deny's field open, the letters type in it.
  expect(permissionKeyAction({ key: "y", target: doc.body, ...plain }, card, true)).toBeUndefined();
});

test("a half-written prompt keeps every key: typing yes into a draft never answers", () => {
  const card = doc.createElement("fieldset");
  const key = (name: string, target: Element, extra: { metaKey?: boolean } = {}) =>
    permissionKeyAction({ key: name, target, ...plain, ...extra }, card, false);
  draft("Please run it but");
  expect(["y", "e", "s", "a", "n", "Enter", "Escape"].map((name) => key(name, editor))).toEqual(
    Array(7).fill(undefined),
  );
  expect(key("Enter", editor, { metaKey: true })).toBeUndefined();
  // Nothing focused, a draft kept: no key answers, letters, digits, Return, ⌘↩ and Esc alike.
  expect(["y", "a", "n", "1", "2", "3", "Enter", "Escape"].map((name) => key(name, doc.body))).toEqual(
    Array(8).fill(undefined),
  );
  expect(key("Enter", doc.body, { metaKey: true })).toBeUndefined();
});

test("a composer holding only attached files keeps every key too", () => {
  const card = doc.createElement("fieldset");
  const key = (name: string, target: Element) => permissionKeyAction({ key: name, target, ...plain }, card, false);
  editor.setAttribute("data-draft-attachments", "");
  try {
    expect(["y", "a", "n", "Enter", "Escape"].map((name) => key(name, editor))).toEqual(Array(5).fill(undefined));
    expect(["y", "a", "n"].map((name) => key(name, doc.body))).toEqual([undefined, undefined, undefined]);
  } finally {
    editor.removeAttribute("data-draft-attachments");
  }
});

async function mountCard(permission: AcpmuxPermission) {
  const root = createRoot(host);
  const answers: string[] = [];
  await act(async () =>
    root.render(<PermissionCard permission={permission} harness="claude" onAnswer={(id) => answers.push(id)} />),
  );
  const press = (key: string, target: Element) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  return { root, answers, press };
}

test("a Claude chat asks to run a command: y from the empty composer runs it, n denies the next", async () => {
  const first = await mountCard(bash("p-yes"));
  await first.press("y", editor);
  expect(first.answers).toEqual(["allow"]);
  await act(async () => first.root.unmount());
  const second = await mountCard(bash("p-no"));
  await second.press("n", editor);
  expect(second.answers).toEqual(["reject"]);
  await act(async () => second.root.unmount());
  const third = await mountCard(bash("p-draft"));
  draft("Typing ");
  for (const letter of ["y", "e", "s"]) await third.press(letter, editor);
  expect(third.answers).toEqual([]);
  await act(async () => third.root.unmount());
});

test("each answer shows its letter on the card, and lists it in aria-keyshortcuts", async () => {
  const { root } = await mountCard(bash("p-hints"));
  const button = (className: string) =>
    host.querySelector<HTMLButtonElement>(`.acpmux-permission-buttons ${className}`)!;
  const keycaps = (element: Element) =>
    [...element.querySelectorAll(".acpmux-keycap")].map((keycap) => keycap.textContent);
  expect(keycaps(button(".acpmux-permission-primary"))[0]).toBe("Y");
  expect(keycaps(button(".acpmux-permission-deny"))[0]).toBe("N");
  const always = [...host.querySelectorAll(".acpmux-permission-buttons button")].find(
    (element) => element.getAttribute("aria-label") === "Always allow",
  )!;
  expect(keycaps(always)[0]).toBe("A");
  expect(button(".acpmux-permission-primary").getAttribute("aria-keyshortcuts")?.split(" ")).toContain("y");
  expect(button(".acpmux-permission-deny").getAttribute("aria-keyshortcuts")?.split(" ")).toContain("n");
  expect(always.getAttribute("aria-keyshortcuts")?.split(" ")).toContain("a");
  await act(async () => root.unmount());
});

const approval = (id: string, at: number): NeedsYouItem => ({
  id: `acpmux:${id}`,
  kind: "approval",
  sessionId: "s1",
  ask: `Run ${id}`,
  who: { name: "Fix login", harness: "claude", chief: false },
  at,
  answers: [
    { id: "allow", label: "Allow", tone: "allow" },
    { id: "reject", label: "Reject", tone: "deny" },
  ],
  permissionId: id,
});

test("Needs you: y and n answer the approval that has focus, the top one from the list itself", async () => {
  const root = createRoot(host);
  const sent: [string, string][] = [];
  const actions = {
    answer: async (item: NeedsYouItem, choice: { id: string }) => {
      sent.push([item.id, choice.id]);
    },
    goTo: () => undefined,
    ask: async () => "",
  };
  const items = [approval("first", 2), approval("second", 1)];
  await act(async () => root.render(<NeedsYouPanel items={items} actions={actions} />));
  const press = (key: string, target: Element) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  const panel = host.querySelector<HTMLElement>(".acpmux-needs-you-panel")!;
  const rows = () => [...host.querySelectorAll<HTMLElement>(".acpmux-needs-you-item")];
  // Focus in the second row: its ask is the one answered.
  await press("n", rows()[1]!.querySelector("button")!);
  expect(sent).toEqual([["acpmux:second", "reject"]]);
  // From the list itself, the top approval.
  await press("y", panel);
  expect(sent).toEqual([
    ["acpmux:second", "reject"],
    ["acpmux:first", "allow"],
  ]);
  await act(async () => root.unmount());
});

test("Needs you: the letters show on the answers and a text field keeps them", async () => {
  const root = createRoot(host);
  const sent: string[] = [];
  const actions = {
    answer: async (item: NeedsYouItem) => {
      sent.push(item.id);
    },
    goTo: () => undefined,
    ask: async () => "",
  };
  await act(async () => root.render(<NeedsYouPanel items={[approval("only", 1)]} actions={actions} />));
  const caps = [...host.querySelectorAll(".acpmux-needs-you-answer .acpmux-keycap")].map((node) => node.textContent);
  expect(caps).toEqual(["Y", "N"]);
  // Ask about this opens a field in the row: typing there answers nothing.
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-needs-you-ask-about")!.click());
  const input = host.querySelector<HTMLInputElement>(".acpmux-needs-you-side-field")!;
  await act(async () => {
    input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "y", bubbles: true, cancelable: true }));
  });
  expect(sent).toEqual([]);
  await act(async () => root.unmount());
});

test("the grouped permission panel answers y, a and n as the card does, never from a draft", async () => {
  const state = {
    supported: true,
    ready: true,
    chatAllowance: false,
    loading: false,
    busy: false,
    groups: [
      {
        groupId: "group-1",
        sessionId: "session-1",
        turnId: "turn-1",
        revision: 3,
        state: "pending",
        decisions: ["allow_once", "allow_chat", "deny"],
        decision: null,
        items: [
          {
            permissionId: "permission-1",
            state: "pending",
            request: { toolCall: { title: "Run npm test", kind: "execute", rawInput: { command: "npm test" } } },
          },
        ],
      },
    ],
  } as unknown as PermissionClientState;
  const responses: string[] = [];
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <PermissionPanel
        state={state}
        working
        onRespond={(_group, _revision, decision) => responses.push(decision)}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  const press = (key: string, target: Element) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  draft("half a thought");
  await press("y", editor);
  expect(responses).toEqual([]);
  draft("");
  await press("y", editor);
  await press("a", doc.body);
  await press("n", doc.body);
  expect(responses).toEqual(["allow_once", "allow_chat", "deny"]);
  await act(async () => root.unmount());
});
