// l10n-allow-file: test fixture asks, not shipped UI.
// A ```ask fence in a reply draws as a choice card; a click sends the option as the next prompt
// (TurnActions `reply`) and the card reads as answered. A fence of another shape stays code.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { parseAskFence } from "./askFence";
import { Markdown } from "./Markdown";
import { TurnActionsContext } from "./turnActions";

const ASK = "Ran the sweep; 3 PRs are stale.\nClose them?\n- Yes, close all\n- Not now\n- Only #12";

test("parses context, question and options", () => {
  expect(parseAskFence(ASK)).toEqual({
    context: ["Ran the sweep; 3 PRs are stale."],
    question: "Close them?",
    options: ["Yes, close all", "Not now", "Only #12"],
  });
  expect(parseAskFence("Pick one\n1. Red\n2) Blue")).toEqual({
    context: [],
    question: "Pick one",
    options: ["Red", "Blue"],
  });
});

test("a fence of another shape is not an ask", () => {
  expect(parseAskFence("Close them?\n- Yes")).toBeUndefined();
  expect(parseAskFence("- Yes\n- No")).toBeUndefined();
  expect(parseAskFence("Close them?\n- Yes\n- No\ntrailing prose")).toBeUndefined();
  expect(parseAskFence("Close them?\n- Yes\n- Yes")).toBeUndefined();
  expect(parseAskFence(`Q?\n${Array.from({ length: 7 }, (_, i) => `- ${i}`).join("\n")}`)).toBeUndefined();
});

test("a closed ask fence draws as a card; an open one or a malformed one stays code", () => {
  const card = renderToStaticMarkup(<Markdown>{"Done.\n\n```ask\n" + ASK + "\n```\n"}</Markdown>);
  expect(card).toContain("cv-ask-card");
  expect((card.match(/cv-ask-option(?!s)/g) ?? []).length).toBe(3);
  // No reply action (a read-only pane): the buttons are disabled.
  expect(card).toContain("disabled");
  const open = renderToStaticMarkup(<Markdown>{"```ask\n" + ASK}</Markdown>);
  expect(open).not.toContain("cv-ask-card");
  const malformed = renderToStaticMarkup(<Markdown>{"```ask\nClose them?\n- Yes\n```\n"}</Markdown>);
  expect(malformed).not.toContain("cv-ask-card");
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.agent/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  dom?.window.close();
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

async function mount(fence: string, reply: (text: string) => Promise<boolean>) {
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={{ reply }}>
        <Markdown>{"```ask\n" + fence + "\n```\n"}</Markdown>
      </TurnActionsContext.Provider>,
    ),
  );
  return dom!.window.document;
}

test("a click sends the option as the next prompt and the card reads as answered", async () => {
  const sent: string[] = [];
  const doc = await mount("Ship it?\n- Ship\n- Hold", async (text) => (sent.push(text), true));
  const hold = [...doc.querySelectorAll<HTMLButtonElement>(".cv-ask-option")].find((b) => b.textContent === "Hold")!;
  await act(async () => hold.click());
  await settle();
  expect(sent).toEqual(["Hold"]);
  expect(doc.querySelector(".cv-ask-card")).toBeNull();
  expect(doc.querySelector(".acpmux-question-answered-answer")?.textContent).toBe("Hold");
});

test("a send that fails gives the buttons back", async () => {
  const doc = await mount("Merge it?\n- Merge\n- Wait", async () => false);
  await act(async () => doc.querySelector<HTMLButtonElement>(".cv-ask-option")!.click());
  await settle();
  expect(doc.querySelector(".cv-ask-card")).not.toBeNull();
  expect(doc.querySelector<HTMLButtonElement>(".cv-ask-option")!.disabled).toBe(false);
});
