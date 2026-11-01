// Session Info enters from the pane's right edge and leaves the way it came (ui/presence.ts, Leo
// 2026-10-20 directional motion): closed, it stays mounted with its sections while its exit plays,
// takes no input, and unmounts when the exit ends; with motion off it goes at once.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  resetSessionInfoState,
  setSessionInfoOpen,
  setSessionInfoSection,
  setSessionInfoWidth,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import type { ProcessRegistry } from "../src/agent-session/acpmux/session-info/processes";
import { activity, assistant, chat, tool, user } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
/// The transition the page's stylesheet would give a surface with presence: 0 is motion off.
let transition = "0.15s";

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  setChatDisplay({});
  const computed = dom.window.getComputedStyle.bind(dom.window);
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: (element: Element) => {
      const style = computed(element);
      if (!element.hasAttribute("data-presence")) return style;
      return { opacity: style.opacity, transitionDuration: transition, transitionDelay: "0s" };
    },
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  transition = "0.15s";
  resetSessionInfoState();
  setHeaderState({ inspector: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const snapshot = chat([user("Write the release notes", 4), assistant("Done.", 3)]);

/// How many times the chat pane around Session Info rendered.
let paneRenders = 0;

function Pane() {
  paneRenders++;
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({ snapshot, machineName: "Studio", shell });
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      {sessionInfo.panel}
    </section>
  );
}

async function mount() {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  return () => container.querySelector<HTMLElement>("aside.acpmux-session-info");
}

test("Session Info slides in from the right and back out, keeping its sections until the exit ends", async () => {
  const panel = await mount();
  await act(async () => setSessionInfoOpen(true));
  const opened = panel();
  expect(opened?.dataset.enter).toBe("right");
  expect(opened?.dataset.presence).toBe("shown");

  await act(async () => setSessionInfoOpen(false));
  const leaving = panel();
  expect(leaving).toBe(opened);
  expect(leaving?.dataset.presence).toBe("leaving");
  expect(leaving?.hasAttribute("inert")).toBe(true);
  expect(leaving?.querySelector("section.acpmux-session-info-section")).not.toBeNull();

  await act(async () => {
    leaving!.dispatchEvent(new dom!.window.Event("transitionend", { bubbles: true }));
  });
  expect(panel()).toBeNull();
});

test("a reopen during the exit keeps the same panel", async () => {
  const panel = await mount();
  await act(async () => setSessionInfoOpen(true));
  const opened = panel();
  await act(async () => setSessionInfoOpen(false));
  await act(async () => setSessionInfoOpen(true));
  expect(panel()).toBe(opened);
  expect(panel()?.dataset.presence).toBe("shown");
  expect(panel()?.hasAttribute("inert")).toBe(false);
});

test("with motion off Session Info closes at once", async () => {
  transition = "0s";
  const panel = await mount();
  await act(async () => setSessionInfoOpen(true));
  expect(panel()).not.toBeNull();
  await act(async () => setSessionInfoOpen(false));
  expect(panel()).toBeNull();
});

// The chat pane (App.tsx AcpmuxPane) is the whole agent pane: each of its renders redraws the
// transcript, the composer and the header. Opening Session Info drew it five times in one frame
// (the store change, the presence's `from` and `shown`, the pane's width), a 75-99 ms frame in the
// gallery's `agent-pane.inspector-motion` `reopened` play. The panel's own phases, its width and its
// folds now render the panel alone.
test("opening, closing, resizing and folding Session Info render the chat pane once per toggle", async () => {
  const panel = await mount();
  const close = async () => {
    await act(async () => setSessionInfoOpen(false));
    await act(async () => {
      panel()!.dispatchEvent(new dom!.window.Event("transitionend", { bubbles: true }));
    });
    expect(panel()).toBeNull();
  };
  await act(async () => setSessionInfoOpen(true));
  await close();

  paneRenders = 0;
  await act(async () => setSessionInfoOpen(true));
  expect(panel()?.dataset.presence).toBe("shown");
  expect(paneRenders).toBe(1);

  paneRenders = 0;
  await act(async () => setSessionInfoWidth(360));
  await act(async () => setSessionInfoSection("environment", false));
  expect(panel()?.style.width).toBe("360px");
  expect(paneRenders).toBe(0);

  paneRenders = 0;
  await close();
  expect(paneRenders).toBe(1);
});

// Leo, 2026-10-22: "why does it FLICKER". A streaming chat sends a new snapshot on every token and
// tool event, and the registry lists the chat's background commands as it learns of them. None of
// that may redraw Session Info from scratch: open, it stays the same panel, shown, and a task row
// stays the same row, including when the registry starts listing a command only the transcript knew
// (its id turns from the call's into the registry's process id).
function StreamPane({ snapshot, registry }: { snapshot: ReturnType<typeof chat>; registry: ProcessRegistry }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({
    snapshot,
    machineName: "Studio",
    shell,
    processes: registry,
    onStopProcess: async () => undefined,
  });
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      {sessionInfo.panel}
    </section>
  );
}

test("open, Session Info and its task rows survive 50 streamed updates without a remount", async () => {
  const container = installDom();
  const call = tool("Type-check in watch mode", "execute", "in_progress", {
    id: "call-tsc",
    inputSummary: JSON.stringify({
      command: "tsc --watch",
      run_in_background: true,
    }),
  });
  const rowsAt = (step: number) => [
    user("Keep the type-checker running and write the notes", 6),
    activity([call], 5, { id: "activity-tsc" }),
    // The reply streams in: a new row object, and longer text, on every update.
    assistant(`Working${".".repeat(step)}`, 1, {
      id: "assistant-streaming",
      version: step + 1,
    }),
  ];
  const registryAt = (step: number): ProcessRegistry =>
    // From update 20 the registry has listed the chat, the type-checker among its processes.
    step < 20
      ? { processes: [], listed: false }
      : {
          processes: [
            {
              id: "s1/tsc",
              command: "tsc --watch",
              toolCallId: "call-tsc",
              startedAt: 1,
              state: "running",
            },
          ],
          listed: true,
        };
  const render = (step: number) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(<StreamPane snapshot={chat(rowsAt(step))} registry={registryAt(step)} />);
    });
  await render(0);
  await act(async () => setSessionInfoSection("tasks", true));
  await act(async () => setSessionInfoOpen(true));
  const panel = () => container.querySelector<HTMLElement>("aside.acpmux-session-info");
  const taskRow = () =>
    container.querySelector<HTMLElement>('[data-section="tasks"] .acpmux-session-info-task--command');
  const opened = panel();
  const row = taskRow();
  expect(opened?.dataset.presence).toBe("shown");
  expect(row?.textContent).toContain("tsc --watch");
  const seen: { step: number; panel: boolean; shown: boolean; row: boolean }[] = [];
  for (let step = 1; step <= 50; step++) {
    await render(step);
    seen.push({
      step,
      panel: panel() === opened,
      shown: panel()?.dataset.presence === "shown",
      row: taskRow() === row,
    });
  }
  expect(seen.filter((update) => !update.panel || !update.shown || !update.row)).toEqual([]);
  // The registry lists it now: the same row has its Stop.
  expect(row?.querySelector("button.acpmux-session-info-stop")).not.toBeNull();
});
