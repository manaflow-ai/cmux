// The To: field's keys, as in Messages: a comma or Return makes the typed text a token (the
// highlighted suggestion first), Backspace with nothing typed deletes a token, Down and Return
// pick from the idle list, and Escape closes the list before it leaves the page.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../../shared/i18n";
import { RecipientField } from "./RecipientField";
import { EMPTY_DRAFT, type HomeContact, type RecipientDraft } from "./recipients";
import { settleReact } from "../../../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

const strings = createStrings({ en: { "home.list.section.chiefs": "Chiefs", "home.compose.section.team": "Team" } }, [
  "en",
]);
const contacts: HomeContact[] = [
  { id: "chief-1", name: "Chief", source: "agent" },
  { id: "p-ada", name: "Ada Park", source: "team" },
  { id: "p-ben", name: "Ben Ito", source: "team" },
];

interface Seen {
  draft: RecipientDraft;
  done: number;
  escaped: number;
  newChief: number;
}

function mount(initial: RecipientDraft = EMPTY_DRAFT) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const seen: Seen = { draft: initial, done: 0, escaped: 0, newChief: 0 };
  function Field() {
    const [draft, setDraft] = useState(initial);
    seen.draft = draft;
    return (
      <RecipientField
        strings={strings}
        draft={draft}
        onDraft={setDraft}
        contacts={contacts}
        idle={contacts.filter((contact) => contact.source !== "connection")}
        onNewChief={() => seen.newChief++}
        onDone={() => seen.done++}
        onEscape={() => seen.escaped++}
      />
    );
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Field />));
  return seen;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const field = () => dom!.window.document.querySelector<HTMLInputElement>('[data-testid="cmux.home.newMessage.to"]')!;
const tokens = () =>
  [...dom!.window.document.querySelectorAll('[data-testid="cmux.home.newMessage.token"]')].map((node) => [
    node.textContent,
    node.hasAttribute("data-invalid"),
  ]);

function type(text: string) {
  const input = field();
  const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, text);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

function press(key: string) {
  act(() => {
    field().dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

test("a comma makes the typed name a token; an unknown name a red one", () => {
  const seen = mount();
  type("Ben Ito,");
  expect(tokens()).toEqual([["Ben Ito", false]]);
  type("Quinn;");
  expect(tokens()).toEqual([
    ["Ben Ito", false],
    ["Quinn", true],
  ]);
  expect(seen.draft.query).toBe("");
});

test("Return picks the highlighted suggestion for the typed text", () => {
  const seen = mount();
  type("ad");
  press("Enter");
  expect(tokens()).toEqual([["Ada Park", false]]);
  expect(seen.done).toBe(0);
});

test("a typed address and a person mix in one draft", () => {
  const seen = mount();
  type("riley@example.com");
  press("Enter");
  type("ben");
  press("Tab");
  expect(tokens()).toEqual([
    ["riley@example.com", false],
    ["Ben Ito", false],
  ]);
  expect(seen.draft.tokens.map((token) => token.recipient?.kind)).toEqual(["address", "contact"]);
});

test("Backspace with nothing typed deletes the selected token, else the last one", () => {
  mount();
  type("Ada Park,");
  type("Ben Ito,");
  type("Quinn,");
  press("Backspace");
  expect(tokens().map(([text]) => text)).toEqual(["Ada Park", "Ben Ito"]);
  act(() => (dom!.window.document.querySelector('[data-testid="cmux.home.newMessage.token"]') as HTMLElement).click());
  press("Backspace");
  expect(tokens().map(([text]) => text)).toEqual(["Ben Ito"]);
  type("x");
  press("Backspace");
  expect(tokens().map(([text]) => text)).toEqual(["Ben Ito"]);
});

test("the idle list highlights nothing until Down; then Down past the header and Return picks", () => {
  const seen = mount();
  press("Enter");
  expect(seen.done).toBe(1);
  expect(tokens()).toEqual([]);
  press("ArrowDown");
  press("Enter");
  expect(tokens()).toEqual([["Chief", false]]);
});

test("Down reaches New Chief, which runs instead of adding a token", () => {
  const seen = mount();
  press("ArrowDown");
  press("ArrowDown");
  press("Enter");
  expect(seen.newChief).toBe(1);
  expect(tokens()).toEqual([]);
});

test("Escape closes a typed list first, then goes to the page", () => {
  const seen = mount();
  type("ad");
  press("Escape");
  expect(seen.escaped).toBe(0);
  expect(dom!.window.document.querySelector('[data-testid="cmux.home.newMessage.suggestions"]')).toBeNull();
  type("");
  press("Escape");
  expect(seen.escaped).toBe(1);
});
