// The shared Button: one class set per variant and size (shadcn's buttonVariants), a type that never
// submits a form by accident, and every native attribute passed through.
import { afterEach, expect, test } from "bun:test";
import { act, createRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Button, buttonClass } from "./Button";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(node: React.ReactNode): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(node));
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("buttonClass defaults to a medium secondary button", () => {
  expect(buttonClass()).toBe("ui-btn ui-btn-secondary ui-btn-md");
  expect(buttonClass({ variant: "primary", size: "lg", className: "x" })).toBe("ui-btn ui-btn-primary ui-btn-lg x");
});

test("Button is a native button that never submits by accident", () => {
  const ref = createRef<HTMLButtonElement>();
  const host = render(
    <form>
      <Button ref={ref} variant="destructive" size="sm" disabled aria-label="Delete">
        Delete
      </Button>
      <Button type="submit">Save</Button>
    </form>,
  );
  const [remove, save] = host.querySelectorAll("button");
  expect(ref.current).toBe(remove);
  expect(remove.type).toBe("button");
  expect(remove.className).toBe("ui-btn ui-btn-destructive ui-btn-sm");
  expect(remove.disabled).toBe(true);
  expect(remove.getAttribute("aria-label")).toBe("Delete");
  expect(save.type).toBe("submit");
});
