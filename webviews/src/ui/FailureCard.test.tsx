// The failure card: the primary is the fix, and the disclosed layout keeps the cause behind its secondary.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { FailureCard, type FailureCardProps } from "./FailureCard";
import { settleReact } from "../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

function mount(props: FailureCardProps) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "MouseEvent", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<FailureCard {...props} />));
  return dom.window.document;
}

const click = (button: HTMLButtonElement) =>
  act(() => {
    button.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  });

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = null;
  await settleReact();
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the card shows its cause and runs the fix", () => {
  const fixed: string[] = [];
  const doc = mount({
    layout: "card",
    title: "Claude Code stopped",
    cause: "Exited with code 137",
    primary: { label: "Retry", onSelect: () => fixed.push("retry") },
  });
  expect(doc.querySelector(".ui-failure__cause")?.textContent).toBe("Exited with code 137");
  const buttons = [...doc.querySelectorAll<HTMLButtonElement>("button")];
  expect(buttons.map((button) => button.textContent)).toEqual(["Retry"]);
  click(buttons[0]!);
  expect(fixed).toEqual(["retry"]);
});

test("the disclosed card opens its cause from the secondary and relabels it", () => {
  const doc = mount({
    layout: "disclosed",
    title: "Claude Code stopped",
    cause: "Exited with code 137",
    primary: { label: "Retry" },
    secondary: { label: "Show log" },
    secondaryOpenLabel: "Hide log",
  });
  expect(doc.querySelector(".ui-failure__raw")).toBeNull();
  const secondary = doc.querySelectorAll<HTMLButtonElement>("button")[1]!;
  expect(secondary.getAttribute("aria-expanded")).toBe("false");
  click(secondary);
  const raw = doc.querySelector(".ui-failure__raw");
  expect(raw?.textContent).toBe("Exited with code 137");
  expect(secondary.getAttribute("aria-expanded")).toBe("true");
  expect(secondary.getAttribute("aria-controls")).toBe(raw?.id ?? null);
  expect(secondary.textContent).toBe("Hide log");
  click(secondary);
  expect(doc.querySelector(".ui-failure__raw")).toBeNull();
});
