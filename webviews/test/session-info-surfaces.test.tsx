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
import { transcriptColumn } from "../src/agent-session/acpmux/model";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import {
  FLOAT_MARGIN,
  SessionInfoPanel,
  pushedWidth,
  pushedRoom,
  sessionInfoFits,
  sessionInfoShown,
  sessionInfoStage,
  paneRoom,
  useSessionInfo,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import { setNativeSessionInfoHost } from "../src/agent-session/acpmux/session-info/native/host";
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
// steps aside, still open for its toggle, so the chat and the new tab are what show. Where the gutter
// cannot hold it the panel pushes the chat (#31423), so it floats over the chat only in a short or too
// narrow pane, as a popover (sessionInfoPopover), which shows only once the person opens it.
function FolderPane({ opened, chatSnapshot = snapshot }: { opened: string[]; chatSnapshot?: typeof snapshot }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({
    snapshot: chatSnapshot,
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
      {sessionInfo.button}
      {sessionInfo.panel}
    </section>
  );
}

async function mountFolderPane(width: number, opened: string[], height = 0) {
  const container = installDom();
  Object.defineProperty(dom!.window.HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("acpmux-shell") ? width : 0;
    },
  });
  Object.defineProperty(dom!.window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("acpmux-shell") ? height : 0;
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
  // A short narrow pane: the panel is a popover over the chat, not a pushed column, and a saved open
  // state alone never shows it there (cmuxterm-hq#6137); the toggle does.
  const container = await mountFolderPane(480, opened, 400);
  expect(panel(container)).toBeNull();
  await act(async () => toggle(container).click());
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

// cmuxterm-hq#6137 (NEXT nightly 1.0.0-nightly.4150738990701): a new chat in a 370px pane opened with
// Session Info over the chat's "Not sent" line, Retry and composer. Where the pane cannot hold a readable
// chat beside the panel at its narrowest (sessionInfoFits), a saved open state leaves the chat clear; the
// toggle opens it over the chat, stopping above the composer (Leo, 2026-11-03: "but you should still be
// able to have it be an overlay... gradually pushing into the chat layout -> overlay").
for (const width of [370, 528]) {
  test(`in a ${width}px pane a saved open state leaves the chat clear; the toggle opens it over the chat above the composer`, async () => {
    const opened: string[] = [];
    const container = await mountFolderPane(width, opened, 960);
    expect(sessionInfoFits(width)).toBe(false);
    expect(panel(container)).toBeNull();
    expect(container.querySelector<HTMLElement>(".acpmux-shell")!.dataset.sessionInfoChatPlacement).toBeUndefined();
    expect(sessionInfoState().open).toBe(true);
    await act(async () => toggle(container).click());
    const card = panel(container) as HTMLElement | null;
    expect(card).not.toBeNull();
    expect(card!.dataset.placement).toBe("overlay");
    expect(card!.hasAttribute("data-over-chat")).toBe(true);
    expect(card!.hasAttribute("data-popover")).toBe(false);
    expect(card!.style.width).toBe("320px");
    expect(container.querySelector<HTMLElement>(".acpmux-shell")!.dataset.sessionInfoChatPlacement).toBe("overlay");
  });
}

test("in a 740px pane a saved open state opens it over the chat: a push would narrow the column", async () => {
  // Leo, 2026-11-03: "the agent chat's horizontal width shouldn't be shifted its position sure but it
  // itself and its text shouldn't be affected by the session info if it would need to be then session
  // info should be an overlay".
  const opened: string[] = [];
  const container = await mountFolderPane(740, opened, 960);
  expect(sessionInfoFits(740)).toBe(true);
  const card = panel(container) as HTMLElement | null;
  expect(card?.dataset.placement).toBe("overlay");
  expect(card?.hasAttribute("data-over-chat")).toBe(true);
  expect(card?.style.width).toBe("320px");
});

test("in a 1100px pane a saved open state opens it, pushing the column left at its own width", async () => {
  const opened: string[] = [];
  const container = await mountFolderPane(1100, opened, 960);
  const card = panel(container) as HTMLElement | null;
  expect(card?.dataset.placement).toBe("push");
  expect(card?.style.width).toBe(`${pushedWidth(1100, 320)}px`);
  const room = pushedRoom(1100, pushedWidth(1100, 320));
  expect(transcriptColumn(1100 - room).width).toBe(transcriptColumn(1100).width);
});

// The App draws the panel natively (#32159) over the page at the page's width and margin from the
// pane's right edge (AgentPaneView+SessionInfo.swift sessionInfoFrame). Pushing, the page keeps the
// room the panel takes (pushedRoom) in the shell's row, so the chat's column moves left beside the
// native panel instead of lying under it. Where a push would narrow the column, the native panel lies
// over the chat: the page keeps none.
for (const width of [370, 528, 740, 1100, 1420]) {
  test(`native, in a ${width}px pane the page keeps the room the native panel takes`, async () => {
    const posted: { open: boolean; width: number; side: number }[] = [];
    setNativeHost(async (method, params) => {
      if (method === "pane.sessionInfo" && params.info) posted.push(params.info as (typeof posted)[number]);
      return {};
    });
    setNativeSessionInfoHost(true);
    try {
      const opened: string[] = [];
      const container = await mountFolderPane(width, opened, 960);
      if (!sessionInfoFits(width)) await act(async () => toggle(container).click());
      await act(async () => new Promise((resolve) => dom!.window.requestAnimationFrame(() => resolve(undefined))));
      const room = container.querySelector<HTMLElement>(".acpmux-session-info-room");
      if (sessionInfoStage("overlay", { width, height: 960 }, 320) !== "push") {
        expect(room).toBeNull();
        expect(posted.at(-1)).toMatchObject({ open: true, width: 320, side: 0 });
        return;
      }
      const expected = pushedWidth(width, 320);
      const taken = pushedRoom(width, expected);
      expect(taken).toBeGreaterThan(0);
      expect(parseFloat(room!.style.width) + parseFloat(room!.style.marginRight)).toBe(taken);
      expect(posted.at(-1)).toMatchObject({ open: true, width: expected, side: 0 });
      // The column keeps its width: it only moves left.
      expect(transcriptColumn(width - taken).width).toBe(transcriptColumn(width).width);
      if (width === 1420) expect(taken).toBeLessThan(expected + FLOAT_MARGIN);
    } finally {
      setNativeSessionInfoHost(false);
      setNativeHost(undefined);
    }
  });
}

test("a narrow pane switched to another chat starts that chat with its transcript clear", async () => {
  // The person opened the popover for one chat; the pane then shows another chat whose saved state is
  // open. The ask was for the first chat, so the second starts unasked.
  const opened: string[] = [];
  const container = await mountFolderPane(370, opened, 960);
  await act(async () => toggle(container).click());
  expect(panel(container)).not.toBeNull();
  const other = { ...snapshot, sessionId: "other-chat", summary: { ...snapshot.summary!, sessionId: "other-chat" } };
  await act(async () => root!.render(<FolderPane opened={opened} chatSnapshot={other} />));
  expect(panel(container)).toBeNull();
  await act(async () => toggle(container).click());
  expect(panel(container)).not.toBeNull();
});

test("a tall pane with room keeps opening Session Info from its saved state", async () => {
  const opened: string[] = [];
  const container = await mountFolderPane(1600, opened, 960);
  expect(panel(container)).not.toBeNull();
});
