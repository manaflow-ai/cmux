// l10n-allow-file: test fixture commands and chat titles, not shipped UI.
// The running line's counts, and a tray command with no terminal, open the Inspector at the section
// that lists what they count (App.tsx `openCommands` and `openTrayCommand`, through processes.ts
// `backgroundSection`): Background tasks while any command runs, a dev server included (its rows head
// that section), and Subagents when only subagents or started chats run. The section is always one
// the Inspector draws. A reveal scrolls to its section once: reopening the Inspector
// later (the palette, a diff split giving the room back) does not jump back to it.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { ChatInspector, useChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { resetInspectorState, setInspectorOpen } from "../src/agent-session/acpmux/inspector/inspectorState";
import {
  backgroundCommands,
  backgroundSection,
  processesOf,
  type InspectorProcess,
} from "../src/agent-session/acpmux/inspector/processes";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { openPicker } from "../src/agent-session/acpmux/pickerOpeners";
import type { StartedSession } from "../src/agent-session/acpmux/started/startedSessions";
import type { SummaryBackgroundTask } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, chat, tool } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
/// The sections scrolled into view, in order.
let scrolled: string[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  setChatDisplay({});
  scrolled = [];
  Object.defineProperty(dom.window.HTMLElement.prototype, "scrollIntoView", {
    configurable: true,
    value(this: HTMLElement) {
      scrolled.push(this.dataset.section ?? "");
    },
  });
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetInspectorState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetInspectorState();
  setHeaderState({ inspector: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// A record as acpmux sends it (hub/processes.rs `Process`).
const wire = (task: string, command: string, state = "running") => ({
  id: `s1/${task}`,
  sessionId: "s1",
  toolCallId: `call-${task}`,
  taskId: task,
  harness: "claude",
  command,
  startedAt: 1_000,
  endedAt: state === "running" ? null : 2_000,
  state,
  origin: "background",
});
const task = (id: string, command: string): SummaryBackgroundTask => ({ id, command, state: "running", startedAt: 1 });
const child: StartedSession = { sessionId: "c1", title: "Migrate the settings store", state: "running", createdAt: 1 };

/// What App.tsx hands `backgroundSection`: the registry's processes and the running commands,
/// servers included (the running line counts them as commands).
const running = (
  processes: readonly InspectorProcess[],
  transcript: readonly SummaryBackgroundTask[],
  listed: boolean,
) => backgroundCommands(processes, transcript, listed).filter((command) => command.state === "running");

const section = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLElement>(`section.acpmux-chat-inspector-section[data-section="${id}"]`);

const cases: {
  name: string;
  processes: InspectorProcess[];
  transcript?: SummaryBackgroundTask[];
  /// The registry listed the chat; without a listing (an older acpmux) the transcript's count.
  listed?: boolean;
  sessions?: StartedSession[];
  expected: "tasks" | "subagents";
}[] = [
  {
    name: "a watcher runs beside a dev server",
    processes: processesOf({ processes: [wire("a", "bun run dev --port 5173"), wire("b", "tsc --watch")] }, "s1"),
    expected: "tasks",
  },
  {
    name: "only a command the transcript knows runs",
    processes: [],
    transcript: [task("call-p", "pytest -x")],
    listed: false,
    expected: "tasks",
  },
  {
    name: "every running command is a dev server, listed under Background tasks",
    processes: processesOf(
      {
        processes: [
          wire("a", "bun run dev --port 5173"),
          wire("b", "python3 -m http.server 8000"),
          wire("c", "tsc --watch", "exited"),
        ],
      },
      "s1",
    ),
    expected: "tasks",
  },
  {
    name: "only a started chat runs",
    processes: processesOf({ processes: [wire("c", "cargo test", "exited")] }, "s1"),
    sessions: [child],
    expected: "subagents",
  },
];

for (const { name, processes, transcript = [], listed = true, sessions = [], expected } of cases)
  test(`the background count opens ${expected} when ${name}, a section the Inspector draws`, async () => {
    expect(backgroundSection(running(processes, transcript, listed))).toBe(expected);
    const container = installDom();
    await act(async () => {
      root = createRoot(container);
      root.render(
        <ChatInspector processes={processes} transcriptTasks={transcript} listed={listed} sessions={sessions} />,
      );
    });
    expect(section(container, expected)).not.toBeNull();
  });

const CWD = "/Users/you/src/atlas-web";
const localChat = chat([
  activity(
    [tool("Edit src/fetch.ts", "edit", "completed", { diffs: [{ path: `${CWD}/src/fetch.ts`, newText: "a\n" }] })],
    3,
  ),
]);

let reveal: ((section: "outputs") => void) | undefined;
function Pane({ snapshot }: { snapshot: AcpmuxSnapshot }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const inspector = useChatInspector({ snapshot, machineName: "Studio", shell });
  reveal = inspector.reveal;
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
          inspector={inspector.button}
        />
      </header>
      {inspector.panel}
    </section>
  );
}

test("a reveal scrolls to its section once; the palette or another pane reopening it does not jump back", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane snapshot={localChat} />);
  });
  await act(async () => setInspectorOpen(false));
  await act(async () => reveal!("outputs"));
  expect(scrolled).toEqual(["outputs"]);
  // Closed (another pane's toggle), then opened from the palette: the Inspector mounts again.
  await act(async () => setInspectorOpen(false));
  expect(container.querySelector("aside.acpmux-chat-inspector")).toBeNull();
  await act(async () => void openPicker("Session Info"));
  expect(container.querySelector("aside.acpmux-chat-inspector")).not.toBeNull();
  // Opened again by another pane's change.
  await act(async () => setInspectorOpen(false));
  await act(async () => setInspectorOpen(true));
  expect(scrolled).toEqual(["outputs"]);
  // A new reveal scrolls again.
  await act(async () => reveal!("outputs"));
  expect(scrolled).toEqual(["outputs", "outputs"]);
});
