// l10n-allow-file: test fixtures (made-up people), not shipped UI.
// The shared chat's faces render from plain fields: the author, the header stack with +N, the
// typing line's words, and nothing at all for a reader alone.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AnsweredBy, AuthorChip, PresenceStack, TypingLine } from "./Faces";
import { ANA, JORDAN, MEI, SAM } from "./people.fixtures";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(node: ReactNode): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
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
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(node);
  });
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the author chip shows the face and the name", () => {
  const host = render(<AuthorChip author={ANA} />);
  expect(host.querySelector(".cv-face")?.textContent).toBe("A");
  expect(host.querySelector(".cv-author__name")?.textContent).toBe("Ana Ruiz");
});

test("the header stacks three faces, then +N, and names everyone for screen readers", () => {
  const host = render(<PresenceStack viewing={[ANA, SAM, MEI, JORDAN]} />);
  expect(host.querySelectorAll(".cv-presence__person")).toHaveLength(3);
  expect([...host.querySelectorAll<HTMLElement>(".cv-presence__person")].map((person) => person.title)).toEqual([
    "Ana Ruiz",
    "Sam Okafor",
    "Mei Lin",
  ]);
  expect(host.querySelector(".cv-presence__more")?.textContent).toBe("+1");
  expect(host.querySelector(".cv-presence__label")?.textContent).toBe(
    "Also here: Ana Ruiz, Sam Okafor, Mei Lin, Jordan Blake",
  );
});

test("a reader alone sees no faces and no typing line", () => {
  const host = render(
    <>
      <PresenceStack viewing={[]} />
      <TypingLine typing={[]} />
    </>,
  );
  expect(host.innerHTML).toBe("");
});

test("the typing line names one, two, or several people", () => {
  expect(render(<TypingLine typing={[ANA]} />).querySelector(".cv-typing__words")?.textContent).toBe(
    "Ana Ruiz is typing…",
  );
  act(() => root?.render(<TypingLine typing={[ANA, SAM]} />));
  expect(dom!.window.document.querySelector(".cv-typing__words")?.textContent).toBe(
    "Ana Ruiz and Sam Okafor are typing…",
  );
  act(() => root?.render(<TypingLine typing={[ANA, SAM, MEI]} />));
  expect(dom!.window.document.querySelector(".cv-typing__words")?.textContent).toBe("Several people are typing…");
  expect(dom!.window.document.querySelectorAll(".cv-typing__dots > i")).toHaveLength(3);
});

test("answered by names the person", () => {
  expect(render(<AnsweredBy person={MEI} />).textContent).toBe("MAnswered by Mei Lin");
});
