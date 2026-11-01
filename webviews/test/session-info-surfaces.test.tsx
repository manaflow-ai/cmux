// Session Info shows only over the chat, where its header toggle is, and it can always be closed
// (session-info/SessionInfo.tsx `sessionInfoShown`, `covered`, `beside`). Leo, 2026-10-22, Session Info
// over a turn's diff in place, its toggle under the hidden header: "WHY DOES IT STAY ON IN THESE
// RANDOM SITUATIONS WITHOUT BEING CLOSABLE!?" While a view takes the pane in the chat's place (a
// diff in place, the event Inspector: App.tsx `covered`) the panel steps aside with its open state
// kept, and comes back when that view closes; opening it (its toggle, the palette, a running line's
// count) closes that view first. Shown, its own x and Esc close it. With a document in the side
// panel beside the chat, the panel measures the chat's room without it and floats clear of it.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import {
  SessionInfoPanel,
  sessionInfoShown,
  paneRoom,
  useSessionInfo,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  sessionInfoState,
  resetSessionInfoState,
  setSessionInfoOpen,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { openPicker } from "../src/agent-session/acpmux/pickerOpeners";
import { ARTIFACT_COVERS_PANE, useArtifactCoversPane } from "../src/agent-session/acpmux/conversation/ArtifactPanel";
import { chat } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  setChatDisplay({});
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
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
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
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

const snapshot = chat([]);
let uncovered = 0;
let reveal: ((section: "outputs") => void) | undefined;
let cover: ((covered: boolean) => void) | undefined;

/// The chat pane as App.tsx wires it: `covered` while a view (a diff in place) has the pane, and
/// `onUncover` closing that view.
function Pane({ initiallyCovered }: { initiallyCovered: boolean }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const [covered, setCovered] = useState(initiallyCovered);
  cover = setCovered;
  const sessionInfo = useSessionInfo({
    snapshot,
    machineName: "Studio",
    shell,
    covered,
    onUncover: () => {
      uncovered += 1;
      setCovered(false);
    },
  });
  reveal = sessionInfo.reveal;
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <header className="acpmux-header">
        <ChatHeaderTools
          onTerminal={() => undefined}
          onBrowser={() => undefined}
          summary={null}
          menu={() => []}
          sessionInfo={sessionInfo.button}
        />
      </header>
      {sessionInfo.panel}
    </section>
  );
}

const panel = (container: HTMLElement) => container.querySelector("aside.acpmux-session-info");
const toggle = (container: HTMLElement) =>
  container.querySelector<HTMLButtonElement>("button.acpmux-session-info-toggle")!;

async function mount(covered: boolean) {
  uncovered = 0;
  const container = installDom();
  await act(async () => setSessionInfoOpen(true));
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane initiallyCovered={covered} />);
  });
  return container;
}

test("it shows only when on, open, not stepped aside for a split, and not covered by another view", () => {
  expect(sessionInfoShown({ on: true, open: true })).toBe(true);
  expect(sessionInfoShown({ on: false, open: true })).toBe(false);
  expect(sessionInfoShown({ on: true, open: false })).toBe(false);
  expect(sessionInfoShown({ on: true, open: true, suppressed: true })).toBe(false);
  expect(sessionInfoShown({ on: true, open: true, covered: true })).toBe(false);
});

test("left open, it steps aside while a diff is in place and is back, still open, when the diff closes", async () => {
  const container = await mount(true);
  expect(panel(container)).toBeNull();
  expect(toggle(container).getAttribute("aria-pressed")).toBe("false");
  // The viewer's open state is kept, for every chat tab.
  expect(sessionInfoState().open).toBe(true);
  await act(async () => cover!(false));
  expect(panel(container)).not.toBeNull();
  expect(toggle(container).getAttribute("aria-pressed")).toBe("true");
  // A diff opened over it again: it steps aside again, and no Esc listener of its own is left.
  await act(async () => cover!(true));
  expect(panel(container)).toBeNull();
  const escape = new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  dom!.window.document.body.dispatchEvent(escape);
  expect(escape.defaultPrevented).toBe(false);
  expect(sessionInfoState().open).toBe(true);
});

// The toggle is in reach over a covered chat when the diff sits beside the transcript (a pane 1160px
// and wider, header.css): the hook's part is that a click there closes the view and opens the panel.
test("its toggle over a covered chat closes that view and opens Session Info over the chat", async () => {
  const container = await mount(true);
  await act(async () => setSessionInfoOpen(false));
  await act(async () => toggle(container).click());
  expect(uncovered).toBe(1);
  expect(panel(container)).not.toBeNull();
  expect(toggle(container).getAttribute("aria-pressed")).toBe("true");
});

test("the palette and a running line's count close the covering view before they open it", async () => {
  const container = await mount(true);
  await act(async () => setSessionInfoOpen(false));
  await act(async () => void openPicker("Session Info"));
  expect(uncovered).toBe(1);
  expect(panel(container)).not.toBeNull();
  await act(async () => cover!(true));
  await act(async () => reveal!("outputs"));
  expect(uncovered).toBe(2);
  expect(panel(container)).not.toBeNull();
});

test("over the chat nothing is closed: the toggle opens and closes it alone", async () => {
  const container = await mount(false);
  expect(panel(container)).not.toBeNull();
  await act(async () => toggle(container).click());
  expect(panel(container)).toBeNull();
  await act(async () => toggle(container).click());
  expect(panel(container)).not.toBeNull();
  expect(uncovered).toBe(0);
});

test("shown, Esc from inside it closes it", async () => {
  const container = await mount(false);
  // No x (Leo, 2026-10-24: "the top bit with the closing mark... it's not necessary"): Esc from a row.
  expect(container.querySelector("aside.acpmux-session-info .acpmux-session-info__close")).toBeNull();
  const row = container.querySelector<HTMLButtonElement>("aside.acpmux-session-info button")!;
  row.focus();
  await act(async () => {
    row.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(panel(container)).toBeNull();
  expect(sessionInfoState().open).toBe(false);
});

test("the chat's room leaves out the side panel beside it, and the floating panel keeps clear of it", () => {
  const container = installDom();
  const shell = dom!.window.document.createElement("section");
  const main = dom!.window.document.createElement("div");
  const side = dom!.window.document.createElement("aside");
  side.className = "acpmux-artifact";
  shell.append(main, side);
  container.append(shell);
  Object.defineProperty(shell, "clientWidth", { value: 1600 });
  Object.defineProperty(shell, "clientHeight", { value: 700 });
  Object.defineProperty(side, "offsetWidth", { value: 736 });
  expect(paneRoom(shell)).toEqual({ width: 864, side: 736, height: 700 });
  side.remove();
  expect(paneRoom(shell)).toEqual({ width: 1600, side: 0, height: 700 });
  // A side panel nested deeper is not beside the chat.
  main.append(side);
  expect(paneRoom(shell)).toEqual({ width: 1600, side: 0, height: 700 });
});

test("floating beside a side panel, the card's right edge is the chat's", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfoPanel width={320} placement="overlay" side={736}>
        <div />
      </SessionInfoPanel>,
    );
  });
  const aside = container.querySelector<HTMLElement>("aside.acpmux-session-info")!;
  expect(aside.style.getPropertyValue("--acpmux-session-info-side")).toBe("736px");
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/session-info/sessionInfo.css", import.meta.url),
    "utf8",
  );
  // Its box ends at the side panel's edge and its inset is its right margin (the same margin as pushing,
  // so a switch between the two places starts no slide: session-info-push-motion.test.ts).
  expect(css).toMatch(
    /\[data-placement="overlay"\] \{[^}]*right: var\(--acpmux-session-info-side, 0px\);[^}]*margin-right: var\(--acpmux-session-info-inset\);/,
  );
});

test("in a narrow pane the side panel covers the whole pane: the query is the stylesheet's", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  );
  const rule = css.match(/@media ([^{]+)\{\s*\.acpmux-artifact \{[^}]*position: absolute;[^}]*inset: 0;/);
  expect(rule?.[1]?.trim()).toBe(ARTIFACT_COVERS_PANE);
});

test("the side panel's covering follows the pane's width as it crosses the query", async () => {
  const container = installDom();
  let matches = false;
  const listeners = new Set<() => void>();
  scope.matchMedia = (query: string) => {
    expect(query).toBe(ARTIFACT_COVERS_PANE);
    return {
      get matches() {
        return matches;
      },
      addEventListener: (_: string, listener: () => void) => listeners.add(listener),
      removeEventListener: (_: string, listener: () => void) => listeners.delete(listener),
    };
  };
  saved.set("matchMedia", undefined);
  const seen: boolean[] = [];
  function Probe() {
    seen.push(useArtifactCoversPane());
    return null;
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Probe />);
  });
  await act(async () => {
    matches = true;
    for (const listener of listeners) listener();
  });
  expect(seen.at(0)).toBe(false);
  expect(seen.at(-1)).toBe(true);
  await act(async () => root!.unmount());
  root = undefined;
  expect(listeners.size).toBe(0);
});

// A handoff review's wider form included: it floats, never a column (Leo, 2026-10-24: "it was never
// supposed to be a sidebar").
test("in a wide pane it floats beside the transcript", async () => {
  const container = installDom();
  // A 1600px pane: the transcript's gutter has room for the floating panel.
  Object.defineProperty(dom!.window.HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("acpmux-shell") ? 1600 : 0;
    },
  });
  await act(async () => setSessionInfoOpen(true));
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane initiallyCovered={false} />);
  });
  expect(panel(container)?.getAttribute("data-placement")).toBe("overlay");
});

// Leo, 2026-10-27: "why am i sent to a whole new thing instead of a tab opening on the right?" The
// project row asks for its Files tab (App.tsx: right of the chat), and a panel floating over the chat
// steps aside, still open for its toggle, so the chat and the new tab are what show.
function FolderPane({ opened }: { opened: string[] }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({
    snapshot,
    machineName: "Studio",
    shell,
    onOpenFolder: (path) => opened.push(path),
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

async function mountFolderPane(width: number, opened: string[]) {
  const container = installDom();
  Object.defineProperty(dom!.window.HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("acpmux-shell") ? width : 0;
    },
  });
  await act(async () => setSessionInfoOpen(true));
  await act(async () => {
    root = createRoot(container);
    root.render(<FolderPane opened={opened} />);
  });
  return container;
}

const projectRow = (container: HTMLElement) =>
  container.querySelector<HTMLButtonElement>('ul[data-section="environment"] button.acpmux-session-info-row')!;

test("over the chat, a project click opens its Files tab and the panel steps aside, still open", async () => {
  const opened: string[] = [];
  const container = await mountFolderPane(480, opened);
  expect(panel(container)).not.toBeNull();
  await act(async () => projectRow(container).click());
  expect(opened).toEqual([snapshot.summary!.cwd!]);
  expect(panel(container)).toBeNull();
  expect(sessionInfoState().open).toBe(true);
});

test("beside the chat, a project click opens its Files tab and the panel stays", async () => {
  const opened: string[] = [];
  const container = await mountFolderPane(1600, opened);
  await act(async () => projectRow(container).click());
  expect(opened).toEqual([snapshot.summary!.cwd!]);
  expect(panel(container)).not.toBeNull();
});
