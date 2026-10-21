// Start Agent's floating chat (cx-b9qi): when the App says its panel holds the chat (`floatingState`), the
// quick page shows the chat's title with keep on top, compact bar and move to tab, and its keys; folded,
// it shows one bar with the chat's state and the reply's last line. The page asks the App to change the
// panel and draws what the App pushes back.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
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
    MouseEvent: window.MouseEvent,
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
          includeContext: () => asked.push("include"),
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
  act(() => button("Include focused tab").click());
  act(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "I", metaKey: true, shiftKey: true, bubbles: true }));
  });
  act(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "j", metaKey: true, bubbles: true }));
  });
  expect(asked.splice(0, 2)).toEqual(["onTop false", "moveToTab"]);
  expect(asked.splice(0, 2)).toEqual(["include", "include"]);
  expect(asked).toEqual(["collapsed true"]);

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
  // Cmd-Shift-P is the app's command palette in every web view (Lawrence 2026-10-19): the page
  // leaves it alone (the app takes it before the page in the real panel); the pin button keeps the
  // panel on top.
  const palette = new KeyboardEvent("keydown", {
    key: "P",
    metaKey: true,
    shiftKey: true,
    bubbles: true,
    cancelable: true,
  });
  act(() => {
    document.dispatchEvent(palette);
  });
  expect(palette.defaultPrevented).toBe(false);
  act(() => button("Keep on top").click());
  expect(asked.slice(1)).toEqual(["collapsed false", "onTop true"]);

  // Moved to a tab: the App lets go, and the next chat is Start Agent's composer again.
  act(() => applyHostEvent({ kind: "floatingState", value: { holding: false, collapsed: false } }));
  expect(host.querySelector(".acpmux-floating-bar")).toBeNull();
  expect(host.querySelector(".acpmux-floating-header")).toBeNull();
});

test("a chat tab's menu offers the floating chat only while the App says it is on", async () => {
  const { headerState, setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  expect(headerState().floatingChat).toBe(false);
  setHeaderState({ pinned: false, sideTabs: false, lit: [], floatingChat: true, version: 1 });
  expect(headerState().floatingChat).toBe(true);
  // A push that leaves it out (an older App) keeps it.
  setHeaderState({ pinned: true, version: 2 });
  expect(headerState().floatingChat).toBe(true);
  setHeaderState({ floatingChat: false, version: 3 });
  expect(headerState().floatingChat).toBe(false);
});

test("Include focused tab attaches what the App read as one chip, or nothing", async () => {
  const { contextAttachment } = await import("../src/agent-session/acpmux/FloatingChat");
  const { promptText } = await import("../src/agent-session/acpmux/attachments");
  const chip = contextAttachment(
    { name: "zsh · ~/src/app (selection)", text: "error: no such module 'Upload'" },
    "Focused tab",
  )!;
  expect(chip.name).toBe("zsh · ~/src/app (selection)");
  // The next prompt carries it under its name; a newer read replaces it (one id).
  expect(promptText("Why does this fail?", [chip])).toContain("zsh · ~/src/app (selection)\n```");
  expect(contextAttachment({ name: "", text: "x" }, "Focused tab")?.id).toBe(chip.id);
  expect(contextAttachment({ name: "", text: "x" }, "Focused tab")?.name).toBe("Focused tab");
  expect(contextAttachment(null, "Focused tab")).toBeUndefined();
  expect(contextAttachment({ name: "Blank", text: "  " }, "Focused tab")).toBeUndefined();
});

test("a right-click on the floating header offers its actions; the bar keeps none", async () => {
  const { createRoot } = await import("react-dom/client");
  const { FloatingHeader, FloatingCompactBar } = await import("../src/agent-session/acpmux/FloatingChat");
  const asked: string[] = [];
  const floating = {
    state: { holding: true, onTop: true, collapsed: false },
    status: "idle",
    title: "Fix the flaky upload test",
    line: "Retrying the third upload.",
    setOnTop: (onTop: boolean) => asked.push(`onTop ${onTop}`),
    setCollapsed: (collapsed: boolean) => asked.push(`collapsed ${collapsed}`),
    moveToTab: () => asked.push("moveToTab"),
    includeContext: () => asked.push("include"),
  };
  const menu = (target: Element) => {
    act(() => {
      target.dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
      );
    });
    return [...document.querySelectorAll<HTMLElement>(".ui-context-menu [role=menuitem]")];
  };
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<FloatingHeader floating={floating as never} />));
  const items = menu(host.querySelector(".acpmux-floating-title")!);
  expect(items.map((item) => item.textContent)).toEqual([
    "Include focused tab",
    "✓Keep on top",
    "Collapse",
    "Move to tab",
  ]);
  act(() => items.at(-1)!.click());
  expect(asked).toEqual(["moveToTab"]);

  // The compact bar's panel is too short for a page-drawn menu: no menu there.
  act(() => document.querySelector<HTMLElement>(".ui-context-menu-backdrop")?.click());
  act(() =>
    root!.render(
      <FloatingCompactBar floating={{ ...floating, state: { ...floating.state, collapsed: true } } as never} />,
    ),
  );
  expect(menu(host.querySelector(".acpmux-floating-bar")!)).toEqual([]);
});
