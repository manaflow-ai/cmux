// Settings > Agent Chat > Session Info `inline` (agentPane.display.sessionInfo.placement): Session Info
// as a band atop the transcript, in the chat's own flow, beside Push and Overlay (the default, which
// stays). Leo, 2026-11-19: "you guys should be customizing the tabs/sidebars a lot deeper too. prob
// likewise the session info" and "if it cant be hot swapped, that's probably an issue with our api/sdk":
// the setting applies live, with no reload.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { importWithDom } from "./support/importWithDom";
import { settleReact } from "./support/domTeardown";

// src/ loads with a document in place (import-order-lint.test.ts): this file installs its own jsdom per test.
const { SESSION_INFO_PLACEMENT_KEY, chatDisplay, sessionInfoPlacementOf, setChatDisplay } = await importWithDom(
  () => import("../src/agent-session/acpmux/chatDisplay"),
);
const { setHeaderState } = await importWithDom(() => import("../src/agent-session/acpmux/header/headerState"));
const { CHAT_CUT } = await importWithDom(() => import("../src/agent-session/acpmux/session-info/chatCut"));
const { SESSION_INFO } = await importWithDom(
  () => import("../src/agent-session/acpmux/session-info/sessionInfoSelectors"),
);
const { inlines } = await importWithDom(() => import("../src/agent-session/acpmux/session-info/sessionInfoModel"));
const { resetSessionInfoState, setSessionInfoMore, setSessionInfoOpen } = await importWithDom(
  () => import("../src/agent-session/acpmux/session-info/sessionInfoState"),
);
const { useSessionInfo } = await importWithDom(() => import("../src/agent-session/acpmux/session-info/useSessionInfo"));
const { activity, chat, tool } = await importWithDom(() => import("../src/gallery/fixtures/acpmux"));

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let observers: (() => void)[] = [];
let paneWidth = 1600;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  observers = [];
  class FakeResizeObserver {
    constructor(private readonly callback: () => void) {
      observers.push(() => this.callback());
    }
    observe() {}
    disconnect() {}
  }
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: FakeResizeObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  setSessionInfoMore(true);
  // Saved open before the chat binds: not asked for in this pane.
  setSessionInfoOpen(true);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => setChatDisplay({}));

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  setHeaderState({ inspector: false });
  setChatDisplay({});
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  paneWidth = 1600;
});

/// The pane as App.tsx lays it out: the stage (the header over the transcript) in the chat's main column,
/// and Session Info's panel a child of the shell.
function Pane({ snapshot }: { snapshot: AcpmuxSnapshot }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({
    snapshot,
    machineName: "Studio",
    shell,
  });
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) {
          Object.defineProperty(element, "clientWidth", {
            configurable: true,
            get: () => paneWidth,
          });
          Object.defineProperty(element, "clientHeight", {
            configurable: true,
            get: () => 900,
          });
          setShell(element);
        }
      }}
    >
      <div className="acpmux-main">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <div className="acpmux-scroll" />
        </div>
      </div>
      {sessionInfo.panel}
    </section>
  );
}

const snapshot = chat([
  activity(
    [
      tool("Edit /Users/you/src/app/src/retry.ts", "edit", "completed", {
        diffs: [
          {
            path: "/Users/you/src/app/src/retry.ts",
            oldText: undefined,
            newText: "x\n",
          },
        ],
      }),
    ],
    1,
  ),
]);

async function render(container: HTMLElement) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Pane snapshot={snapshot} />);
  });
}

const panel = (container: HTMLElement) => container.querySelector<HTMLElement>(SESSION_INFO);
const shellOf = (container: HTMLElement) => container.querySelector<HTMLElement>(".acpmux-shell")!;

test("the saved placement reads inline, push and overlay, and anything else as the default overlay", () => {
  expect(sessionInfoPlacementOf("inline")).toBe("inline");
  expect(sessionInfoPlacementOf("push")).toBe("push");
  expect(sessionInfoPlacementOf("overlay")).toBe("overlay");
  expect(sessionInfoPlacementOf("sideways")).toBe("overlay");
  expect(sessionInfoPlacementOf(undefined)).toBe("overlay");
  setChatDisplay({});
  expect(chatDisplay().sessionInfo).toBe("overlay");
  setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "inline" });
  expect(chatDisplay().sessionInfo).toBe("inline");
  expect(inlines(chatDisplay().sessionInfo)).toBe(true);
  setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "push" });
  expect(inlines(chatDisplay().sessionInfo)).toBe(false);
});

test("inline draws Session Info as a band in the chat's stage under the header, and switches live", async () => {
  const container = installDom();
  setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "inline" });
  await render(container);
  const band = panel(container);
  expect(band).not.toBeNull();
  // In the chat's flow: inside the stage, not beside the chat in the shell.
  expect(band!.parentElement?.classList.contains("acpmux-stage")).toBe(true);
  expect(band!.dataset.placement).toBe("inline");
  // The column's width (CSS), no dragged width, no glass, and no cut out of the transcript.
  expect(band!.style.width).toBe("");
  expect(band!.classList.contains("ui-glass")).toBe(false);
  expect(band!.hasAttribute("data-over-chat")).toBe(false);
  expect(band!.hasAttribute("data-popover")).toBe(false);
  expect(shellOf(container).dataset.sessionInfoChatPlacement).toBe("inline");
  expect(shellOf(container).style.getPropertyValue(CHAT_CUT)).toBe("");

  // Live to Overlay: the same open panel moves beside the chat, in the shell.
  await act(async () => setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "overlay" }));
  expect(panel(container)?.dataset.placement).toBe("overlay");
  expect(panel(container)?.parentElement).toBe(shellOf(container));
  expect(container.querySelector(`.acpmux-stage > ${SESSION_INFO}`)).toBeNull();
  expect(shellOf(container).dataset.sessionInfoChatPlacement).toBe("overlay");

  // Push still pushes.
  await act(async () => setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "push" }));
  expect(panel(container)?.dataset.placement).toBe("push");

  // And back to Inline.
  await act(async () => setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "inline" }));
  expect(panel(container)?.dataset.placement).toBe("inline");
  expect(panel(container)?.parentElement?.classList.contains("acpmux-stage")).toBe(true);
});

test("a narrow pane does not hold the saved-open inline band closed, as it holds a side panel", async () => {
  // Overlay (the default) in a 600px pane: held closed until the person opens it (a popover then).
  let container = installDom();
  paneWidth = 600;
  await render(container);
  expect(panel(container)).toBeNull();
  await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  setSessionInfoOpen(true);
  // Inline fits any pane: it shows, never a popover.
  container = dom!.window.document.getElementById("root")!;
  setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "inline" });
  await render(container);
  expect(panel(container)?.dataset.placement).toBe("inline");
  expect(panel(container)?.hasAttribute("data-popover")).toBe(false);
});
