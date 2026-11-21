// l10n-allow-file: test fixture subagent tasks, not shipped UI.
// The composer hat's marks in the live pane (subagents/hatSidePlace.ts, ComposerBox.tsx `hatMarks`;
// Leo, 2026-11-21: "this is uncomfortably tight. didn't we say we wanted to move these to the side or
// smth?"). The host below composes the pieces exactly as App.tsx does: `useHatSidePlace` decides
// whether the hat draws over the composer, the real ComposerBox takes the rail (HatRail.tsx), and the
// arm comes through the experiment's own switch (`globalThis.cmuxExperiments`, as the gallery and the
// `cmux.experiments` debug key set it). Each arm: where the marks stand, that a click on a mark opens
// its line, and in a side arm that the list control shows the hat over the composer and its fold
// puts it away.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "IntersectionObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
  "MouseEvent",
  "PointerEvent",
  "Event",
  "localStorage",
  "cmuxExperiments",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let host: HTMLElement;
let unmount: (() => Promise<void>) | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    MouseEvent: window.MouseEvent,
    Event: window.Event,
    localStorage: window.localStorage,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope))
      scope[key] = (window as unknown as Record<string, unknown>)[key];
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await unmount?.();
  unmount = undefined;
  host.replaceChildren();
  delete scope.cmuxExperiments;
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const { act, createElement, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { ComposerBox } = await import("../src/agent-session/acpmux/ComposerBox");
const { HatRail } = await import("../src/agent-session/acpmux/subagents/HatRail");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { useHatSidePlace } = await import("../src/agent-session/acpmux/subagents/hatSidePlace");
const { trayItems } = await import("../src/agent-session/acpmux/subagents/runningTray");
const { resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
type ComposerAttachment = import("../src/agent-session/acpmux/attachments").ComposerAttachment;
setPaneLanguage("en");

const now = Date.now();
const agent = (id: string, task: string, startedAgo: number): Subagent => ({
  id,
  parent: null,
  name: id,
  task,
  state: "running",
  startedAt: now - startedAgo,
});
const AGENTS = [agent("a1", "Review the tray", 50_000), agent("a2", "Audit the stack", 3_000)];

/// The pane's bottom stack as App.tsx composes it: the hat over the composer while `hatShown`, the
/// composer with the rail while the arm is a side one.
async function pane(arm: string) {
  scope.cmuxExperiments = { "composer-hat-side": arm };
  resetTrayOpenMemory();
  const opened: string[] = [];
  const items = trayItems(AGENTS, [], [], true);
  const waiting = new Set<string>();
  const onOpen = (id: string) => opened.push(id);
  function Host() {
    const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
    const place = useHatSidePlace("chat-1", items.length > 0);
    return createElement(
      "div",
      { className: "acpmux-dock" },
      place.hatShown &&
        createElement(SubagentTray, {
          key: "chat-1",
          chat: "chat-1",
          items,
          working: true,
          waiting,
          onOpen,
          onFold: place.side ? () => place.onList(false) : undefined,
        }),
      createElement(
        "form",
        { className: "acpmux-composer" },
        createElement(ComposerBox, {
          field: { value: "", onChange: () => {} },
          attachments,
          setAttachments: (update) => setAttachments(update),
          onRemoveAttachment: () => {},
          fieldMenu: [],
          chromeItems: [],
          leading: createElement("span", { className: "test-plus" }, "+"),
          trailing: createElement("button", { type: "button", className: "test-send" }, "Send"),
          hatMarks: place.side
            ? {
                side: place.side,
                node: createElement(HatRail, {
                  side: place.side,
                  items,
                  waiting,
                  listOpen: place.listOpen,
                  onOpen,
                  onList: place.onList,
                }),
              }
            : undefined,
        }),
      ),
    );
  }
  const root = createRoot(host);
  await act(async () => root.render(createElement(Host)));
  unmount = async () => act(async () => root.unmount());
  const click = async (node: Element) =>
    act(async () => {
      node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));
    });
  return {
    opened,
    click,
    box: () => host.querySelector<HTMLElement>(".acpmux-composer-box")!,
    rail: () => host.querySelector<HTMLElement>(".acpmux-hat-rail"),
    hat: () => host.querySelector<HTMLElement>(".acpmux-running-tray"),
    railMark: (key: string) => host.querySelector<HTMLButtonElement>(`.acpmux-hat-rail [data-rolodex-key="${key}"]`),
    list: () => host.querySelector<HTMLButtonElement>(".acpmux-hat-rail__list"),
  };
}

describe("the composer hat's marks in the live pane, by arm", () => {
  test("top (the default): the hat over the composer as before, no rail, its header mark opens the line", async () => {
    const view = await pane("top");
    expect(view.hat()).toBeTruthy();
    expect(view.rail()).toBeNull();
    expect(view.box().hasAttribute("data-hat-rail")).toBe(false);
    // The hat sits before the composer in the stack.
    expect(view.hat()!.compareDocumentPosition(view.box()) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    const thumb = view.hat()!.querySelector('[data-rolodex-key="agent:a2"]');
    expect(thumb).toBeTruthy();
    await view.click(thumb!);
    expect(view.opened).toEqual(["a2"]);
  });

  test("no arm set reads as top", async () => {
    const view = await pane("not-an-arm");
    expect(view.hat()).toBeTruthy();
    expect(view.rail()).toBeNull();
  });

  for (const side of ["right-rail", "left-rail"] as const)
    test(`${side}: the rail stands at the box's edge, no hat; a mark opens its line; the list shows the hat and its fold puts it away`, async () => {
      const view = await pane(side);
      expect(view.hat()).toBeNull();
      const rail = view.rail()!;
      expect(rail).toBeTruthy();
      expect(rail.dataset.side).toBe(side);
      // The box's own child, which the box makes room for at that side (hatRail.css).
      expect(rail.parentElement).toBe(view.box());
      expect(view.box().dataset.hatRail).toBe(side);
      expect(rail.closest(".acpmux-composer-bar")).toBeNull();
      await view.click(view.railMark("agent:a1")!);
      expect(view.opened).toEqual(["a1"]);
      // The list control: the hat, opened on its lines, over the composer.
      await view.click(view.list()!);
      expect(view.hat()).toBeTruthy();
      expect(view.list()!.getAttribute("aria-expanded")).toBe("true");
      expect(view.hat()!.querySelectorAll(".acpmux-running-tray__row, [data-tray-row]").length).toBeGreaterThan(0);
      // Folding it from its header puts it away; the rail stays.
      await view.click(view.hat()!.querySelector(".acpmux-running-tray__head")!);
      expect(view.hat()).toBeNull();
      expect(view.list()!.getAttribute("aria-expanded")).toBe("false");
      expect(view.rail()).toBeTruthy();
    });

  test("bottom-line: the marks on the button row right after +, before the send controls; a mark opens its line", async () => {
    const view = await pane("bottom-line");
    expect(view.hat()).toBeNull();
    const rail = view.rail()!;
    expect(rail).toBeTruthy();
    expect(view.box().hasAttribute("data-hat-rail")).toBe(false);
    expect(rail.parentElement?.classList.contains("acpmux-composer-bar")).toBe(true);
    expect(rail.previousElementSibling?.classList.contains("test-plus")).toBe(true);
    expect(rail.nextElementSibling?.classList.contains("acpmux-composer-actions")).toBe(true);
    await view.click(view.railMark("agent:a2")!);
    expect(view.opened).toEqual(["a2"]);
    await view.click(view.list()!);
    expect(view.hat()).toBeTruthy();
  });
});
