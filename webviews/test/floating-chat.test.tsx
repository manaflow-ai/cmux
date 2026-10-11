// Start Agent's floating chat (cx-b9qi): when the App says its panel holds the chat (`floatingState`), the
// quick page shows the chat's title with keep on top, compact bar and move to tab, and its keys; folded,
// it shows one bar with the chat's state and the reply's last line. The page asks the App to change the
// panel and draws what the App pushes back.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
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

test("the floating chat's header and compact bar follow the App and ask it to change the panel", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QuickSurface } = await import("../src/agent-session/acpmux/QuickSurface");
  const { floatingStatus } = await import("../src/agent-session/acpmux/FloatingChat");
  const { useFloatingState } = await import("../src/agent-session/acpmux/floatingState");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const asked: string[] = [];
  let status = floatingStatus(false, true);

  function Page() {
    const state = useFloatingState();
    return (
      <QuickSurface
        transcript={<p>Uploads now retry server errors.</p>}
        composer={<div className="acpmux-composer" />}
        floating={{
          state,
          status,
          title: "Fix the flaky upload test",
          line: "Retrying the third upload.",
          setOnTop: (onTop) => asked.push(`onTop ${onTop}`),
          setCollapsed: (collapsed) => asked.push(`collapsed ${collapsed}`),
          moveToTab: () => asked.push("moveToTab"),
        }}
      />
    );
  }

  root = createRoot(host);
  act(() => root!.render(<Page />));
  // A draft (the panel does not hold it yet) is Start Agent's composer: no floating header.
  expect(host.querySelector(".acpmux-floating-header")).toBeNull();
  expect(host.querySelector(".acpmux-quick-keys")?.textContent).toContain("start");

  act(() => applyHostEvent({ kind: "floatingState", value: { holding: true, onTop: true, collapsed: false } }));
  const header = host.querySelector(".acpmux-floating-header")!;
  expect(header.textContent).toContain("Fix the flaky upload test");
  const button = (label: string) => host.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!;
  expect(button("Keep on top").getAttribute("aria-pressed")).toBe("true");
  expect(host.querySelector(".acpmux-quick-keys")?.textContent).toContain("move to tab");
  expect(host.querySelector('.acpmux-floating-status[data-status="streaming"]')).not.toBeNull();

  act(() => button("Keep on top").click());
  act(() => button("Move to tab").click());
  act(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "j", metaKey: true, bubbles: true }));
  });
  expect(asked).toEqual(["onTop false", "moveToTab", "collapsed true"]);

  // The App folded the panel and the chat now waits on the user.
  status = floatingStatus(true, true);
  act(() => applyHostEvent({ kind: "floatingState", value: { onTop: false, collapsed: true } }));
  expect(host.querySelector(".acpmux-floating-header")).toBeNull();
  expect(host.querySelector(".acpmux-quick-thread")).toBeNull();
  const bar = host.querySelector(".acpmux-floating-bar")!;
  expect(bar.getAttribute("data-status")).toBe("attention");
  expect(bar.textContent).toContain("Retrying the third upload.");
  expect(button("Keep on top").getAttribute("aria-pressed")).toBe("false");
  act(() => host.querySelector<HTMLButtonElement>(".acpmux-floating-bar-open")!.click());
  act(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "P", metaKey: true, shiftKey: true, bubbles: true }));
  });
  expect(asked.slice(3)).toEqual(["collapsed false", "onTop true"]);

  // Moved to a tab: the App lets go, and the next chat is Start Agent's composer again.
  act(() => applyHostEvent({ kind: "floatingState", value: { holding: false, collapsed: false } }));
  expect(host.querySelector(".acpmux-floating-bar")).toBeNull();
  expect(host.querySelector(".acpmux-floating-header")).toBeNull();
});
