// Chat animation ordering map, orders O20 and O25 (design/chat-animation-ordering-map.md, A2).
// Leo: "some animations i think are still a bit... off. like, you finish some sort of tool call, things
// happen, things fold, stuff comes in at different times".
// O20: a collapsible's body unmounted and remounted (scrolled away and back) draws at its `open` with
// no fold. O25: a late update inside a folded (closed) Worked plays nothing: the fold reacts only to
// `open`, so the version bump of a closed body is drawn silently.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useFold } from "../src/agent-session/acpmux/conversation/fold";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
let animated = 0;

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
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  animated = 0;
  (dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function () {
    animated += 1;
    return { currentTime: null, onfinish: null, oncancel: null, cancel() {} };
  };
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

function Box({ open, text }: { open: boolean; text: string }) {
  const { present, ref } = useFold(open);
  return (
    <div>
      {present ? (
        <div ref={ref} className="cv-fold">
          {text}
        </div>
      ) : null}
    </div>
  );
}
function render(node: React.ReactNode) {
  act(() => {
    root ??= createRoot(container);
    root.render(node);
  });
}

test("O20: a body remounted open draws open with no fold, and one remounted closed draws nothing", () => {
  render(<Box open text="a" />);
  expect(container.querySelector(".cv-fold")).not.toBeNull();
  act(() => root!.unmount());
  root = undefined;
  render(<Box open text="a" />);
  expect(container.querySelector(".cv-fold")?.textContent).toBe("a");
  expect(animated).toBe(0);
  act(() => root!.unmount());
  root = undefined;
  render(<Box open={false} text="a" />);
  expect(container.querySelector(".cv-fold")).toBeNull();
  expect(animated).toBe(0);
});

test("O25: a late update inside a closed (folded) body plays no fold and draws nothing", () => {
  render(<Box open={false} text="a" />);
  render(<Box open={false} text="a, then a late tool result" />);
  render(<Box open={false} text="a, then another" />);
  expect(container.querySelector(".cv-fold")).toBeNull();
  expect(animated).toBe(0);
});

test("O25: a late update inside an open body changes its text without playing a second fold", () => {
  render(<Box open text="a" />);
  render(<Box open text="a, then a late tool result" />);
  expect(container.querySelector(".cv-fold")?.textContent).toBe("a, then a late tool result");
  expect(animated).toBe(0);
});
