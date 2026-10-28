// l10n-allow-file: test fixture chat titles and paths, not shipped UI.
// No dead clicks in the chat header (Leo 2026-10-21): every item in the header row does something when
// clicked. The row as App.tsx draws it: the panel toggle (the summary's with the Inspector off,
// the Inspector's with it on), the Needs you inbox, every quick action and the "..." menu.
// Each one is clicked on its own fresh render and must call its action, open its popup or flip
// its toggle. Machine and folder are composer chips, never header buttons.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { configureQuickActions } from "../src/agent-session/acpmux/header/quickActions";
import { useChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { resetInspectorState } from "../src/agent-session/acpmux/inspector/inspectorState";
import { NeedsYouButton } from "../src/agent-session/acpmux/needsYou/NeedsYou";
import { SummaryButton } from "../src/agent-session/acpmux/summary/SummaryButton";
import { activity, chat, tool } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(inspector: boolean): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector });
  class FakeResizeObserver {
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
  for (const key of Object.keys(replacements)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetInspectorState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetInspectorState();
  configureQuickActions({});
  setHeaderState({ inspector: false, pullRequest: null });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const CWD = "/Users/you/src/atlas-web";
const snapshot = chat([
  activity(
    [
      tool(`Edit ${CWD}/src/fetch.ts`, "edit", "completed", {
        diffs: [{ path: `${CWD}/src/fetch.ts`, oldText: "a\n", newText: "a\nb\n" }],
      }),
    ],
    1,
  ),
]);

/// The header row as App.tsx draws it, every action recorded by name.
function Header({ calls }: { calls: string[] }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const inspector = useChatInspector({ snapshot, machineName: "Studio", shell });
  const record = (name: string) => () => void calls.push(name);
  const [summaryShown, setSummaryShown] = useState(false);
  const card = {
    shown: summaryShown,
    toggle: () => {
      calls.push("summary");
      setSummaryShown((shown) => !shown);
    },
    show: record("summary.show"),
  };
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <header className="acpmux-header">
        <div className="acpmux-handoff-header-tools">
          <ChatHeaderTools
            onTerminal={record("terminal")}
            onSplitDown={record("splitDown")}
            onBrowser={record("browser")}
            hasChanges
            onChanges={record("changes")}
            onFiles={record("files")}
            previewUrl="http://localhost:5173/"
            onPreview={record("preview")}
            onSideTabs={record("newTab")}
            summary={inspector.on ? null : <SummaryButton card={card as never} />}
            menu={() => [{ key: "rename", label: "Rename", icon: "action.edit", onSelect: record("rename") }]}
            inspector={inspector.button}
            inbox={
              <NeedsYouButton
                items={[]}
                actions={{ answer: async () => undefined, goTo: record("needsYou.goTo"), ask: async () => undefined }}
              />
            }
          />
        </div>
      </header>
      {inspector.panel}
    </section>
  );
}

/// What a click can change: an action called, a popup or toggle state, an Inspector section lit,
/// a popup in the document.
function fingerprint(container: HTMLElement, calls: string[]): string {
  const document = container.ownerDocument;
  const states = [...container.querySelectorAll<HTMLElement>("header button")].map(
    (button) => `${button.getAttribute("aria-expanded")}/${button.getAttribute("aria-pressed")}`,
  );
  const lit = [...document.querySelectorAll<HTMLElement>("[data-revealed]")].map((section) => section.dataset.section);
  const popups = document.querySelectorAll("[role=menu], [role=dialog]").length;
  return JSON.stringify({
    calls,
    states,
    lit,
    popups,
    inspector: !!document.querySelector("aside.acpmux-chat-inspector"),
  });
}

async function everyItemActs(inspector: boolean, before?: () => void) {
  const labels: string[] = [];
  for (let index = 0; ; index++) {
    const container = installDom(inspector);
    configureQuickActions({
      quickActions: ["changes", "preview", "files", "terminal", "splitDown", "browser", "newTab"],
    });
    const calls: string[] = [];
    await act(async () => {
      root = createRoot(container);
      root.render(<Header calls={calls} />);
    });
    before?.();
    await act(async () => undefined);
    const items = [...container.querySelectorAll<HTMLElement>("header button")];
    const item = items[index];
    if (!item) break;
    const label = item.getAttribute("aria-label") ?? "";
    labels.push(label);
    // Every item in the row is a live button: none is disabled, none is decoration.
    expect([label, (item as HTMLButtonElement).disabled]).toEqual([label, false]);
    const was = fingerprint(container, calls);
    await act(async () => item.click());
    expect([label, fingerprint(container, calls)]).not.toEqual([label, was]);
    await act(async () => root!.unmount());
    root = undefined;
    resetInspectorState();
    configureQuickActions({});
    dom?.window.close();
  }
  return labels;
}

test("with the Inspector on, every header item acts on a click", async () => {
  setChatDisplay({});
  const labels = await everyItemActs(true);
  // The Inspector's toggle leads the top-right tools, as Claude Code desktop's panel toggle does.
  expect(labels).toEqual([
    "Session Info",
    "Needs you",
    "Changes",
    "Preview",
    "Files",
    "Terminal",
    "Split Down",
    "Browser",
    "New tab",
    "Chat actions",
  ]);
});

test("with the Inspector off, every header item acts on a click", async () => {
  setChatDisplay({});
  const labels = await everyItemActs(false);
  expect(labels).toEqual([
    "Chat summary",
    "Needs you",
    "Changes",
    "Preview",
    "Files",
    "Terminal",
    "Split Down",
    "Browser",
    "New tab",
    "Chat actions",
  ]);
});
