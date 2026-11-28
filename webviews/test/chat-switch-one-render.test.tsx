// A chat switch renders the pane once: state that belongs to the shown chat (its folds, its subagent
// view, its share dialog, its fade) begins at the chat's own in the render that shows it
// (pane/useChatState.ts). Set during render instead, React threw that render away and rendered the
// whole pane again on every switch (settled-page bench, chat_switch: AcpmuxPane drawn twice).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type Dispatch, type SetStateAction } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import { useChatState } from "../src/agent-session/acpmux/pane/useChatState";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

type Folds = { chat: string | undefined; open: Set<string> };
const seen: { renders: number; folds?: Folds; set?: Dispatch<SetStateAction<Folds>>; left?: string } = { renders: 0 };
const kept = new Map<string, Folds>();

function Pane({ chat }: { chat: string | undefined }) {
  seen.renders += 1;
  const [folds, setFolds] = useChatState<Folds>(chat, (shown, left) => {
    seen.left = left?.chat;
    return (shown === undefined ? undefined : kept.get(shown)) ?? { chat: shown, open: new Set() };
  });
  if (chat !== undefined) kept.set(chat, folds);
  seen.folds = folds;
  seen.set = setFolds;
  return null;
}

test("a switch renders the pane once, with the shown chat's own state, and a switch back has what it left", async () => {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  act(() => root!.render(<Pane chat="a" />));
  act(() => seen.set!((folds) => ({ ...folds, open: new Set(["a-turn"]) })));
  const foldsA = seen.folds!;
  expect([...foldsA.open]).toEqual(["a-turn"]);

  seen.renders = 0;
  act(() => root!.render(<Pane chat="b" />));
  expect(seen.renders).toBe(1);
  expect(seen.left).toBe("a");
  expect(seen.folds).toEqual({ chat: "b", open: new Set() });
  const foldsB = seen.folds;
  // A render of the same chat keeps the very value it began at: turnViewFrom reuses turns by identity.
  act(() => root!.render(<Pane chat="b" />));
  expect(seen.folds).toBe(foldsB);
  // A set from a callback applies to the chat shown now.
  act(() => seen.set!((folds) => ({ ...folds, open: new Set(["b-turn"]) })));
  expect(seen.folds).toEqual({ chat: "b", open: new Set(["b-turn"]) });

  seen.renders = 0;
  act(() => root!.render(<Pane chat="a" />));
  expect(seen.renders).toBe(1);
  expect(seen.folds).toBe(foldsA);
});
