// Directional enter and exit (ui/presence.ts, Leo 2026-10-20): a side panel slides in from its edge
// and leaves the way it came. It stays mounted while its exit plays, a reopen during the exit
// reverses it in place, a second open changes nothing, and with motion off it goes at once. A change
// of placement (`snapOn`, which a resize picks) shows or hides it with no enter or exit.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "getComputedStyle",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let doc: Document;
let window: JSDOM["window"];
/// The transition the page's stylesheet would give a surface: 0 is motion off.
let transition = "0.15s";

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  const computed = window.getComputedStyle.bind(window);
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: window.HTMLElement,
    getComputedStyle: (element: Element) => {
      const style = computed(element);
      if (!element.hasAttribute("data-presence")) return style;
      return { opacity: style.opacity, transitionDuration: transition, transitionDelay: "0s" };
    },
  });
  doc = window.document;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function mount() {
  const { createRoot } = await import("react-dom/client");
  const { usePresence } = await import("../src/ui/presence");
  phases.length = 0;
  function Panel({ shown, placement }: { shown: boolean; placement?: string }) {
    const presence = usePresence(shown, "right", { snapOn: placement });
    if (presence.present) phases.push(presence.props["data-presence"]);
    return presence.present ? <aside {...presence.props} inert={presence.leaving} className="panel" /> : null;
  }
  act(() => root?.unmount());
  root = createRoot(doc.getElementById("root")!);
  return (shown: boolean, placement?: string) => act(() => root!.render(<Panel shown={shown} placement={placement} />));
}

/// Every phase the panel rendered with, in order.
const phases: string[] = [];

const panel = () => doc.querySelector<HTMLElement>(".panel");

test("a panel enters from its edge, stays while its exit plays, and goes when the exit ends", async () => {
  transition = "0.15s";
  const render = await mount();
  render(false);
  expect(panel()).toBeNull();
  render(true);
  expect(panel()?.dataset.enter).toBe("right");
  expect(panel()?.dataset.presence).toBe("shown");
  const node = panel();
  render(true);
  expect(panel()).toBe(node);
  expect(panel()?.dataset.presence).toBe("shown");
  render(false);
  expect(panel()?.dataset.presence).toBe("leaving");
  expect(panel()?.hasAttribute("inert")).toBe(true);
  act(() => {
    panel()!.dispatchEvent(new window.Event("transitionend", { bubbles: true }));
  });
  expect(panel()).toBeNull();
});

test("a reopen during the exit reverses the same panel in place", async () => {
  transition = "0.15s";
  const render = await mount();
  render(true);
  const node = panel();
  render(false);
  expect(panel()?.dataset.presence).toBe("leaving");
  render(true);
  expect(panel()).toBe(node);
  expect(panel()?.dataset.presence).toBe("shown");
});

test("with motion off a closed panel goes at once", async () => {
  transition = "0s";
  const render = await mount();
  render(true);
  render(false);
  expect(panel()).toBeNull();
});

// Leo 2026-10-21, a pane opening or closing on the right of a chat with its summary open: "it just
// destroys the overlay". The narrower pane moves the summary from its column to a popover; that
// switch is the layout's, so the column never plays an exit drawn as a popover, and it comes back
// with no entrance when the pane closes.
test("a change of placement shows or hides the panel at once, with no enter or exit", async () => {
  transition = "0.15s";
  const render = await mount();
  render(true, "inline");
  expect(panel()?.dataset.presence).toBe("shown");
  render(false, "popover");
  expect(panel()).toBeNull();
  phases.length = 0;
  render(true, "inline");
  expect(panel()?.dataset.presence).toBe("shown");
  expect(phases).not.toContain("from");
  // A click on the same placement still slides it.
  render(false, "inline");
  expect(panel()?.dataset.presence).toBe("leaving");
  phases.length = 0;
  render(true, "inline");
  render(false, "inline");
  act(() => {
    panel()!.dispatchEvent(new window.Event("transitionend", { bubbles: true }));
  });
  phases.length = 0;
  render(true, "inline");
  expect(phases[0]).toBe("from");
});
