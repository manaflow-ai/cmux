// The Inspector (Debug Settings `agent.inspector`, on by default; Claude Code desktop's session
// panel with ChatGPT's subagents row): with the flag on, the header's top-right toggle opens a
// panel at the right of the chat with where it runs (Environment), how much of the context window
// it used (Context), its MCP servers (Connectors), the pull requests it opened or touched
// (Changes), its subagents, its background commands and what it produced (Outputs). It is open by
// default, stays open (or closed) across chat panes, pushes the chat aside unless the pane is too
// narrow or Settings says Overlay, and lists every row, scrolling instead of a "Show more".
import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { act, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { INSPECTOR_PLACEMENT_KEY, setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import {
  ChatInspector,
  pushes,
  PUSH_MIN_CHAT,
  useChatInspector,
} from "../src/agent-session/acpmux/inspector/ChatInspector";
import {
  inspectorState,
  resetInspectorState,
  setInspectorSection,
} from "../src/agent-session/acpmux/inspector/inspectorState";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, chat, tool } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

/// ResizeObservers the page made, so a test can resize the pane.
let observers: (() => void)[] = [];

function installDom(inspector: boolean): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  // The App pushes Debug Settings `agent.inspector` with the header state.
  setHeaderState({ inspector });
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
    // Base UI's Collapsible schedules its open and close on animation frames.
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetInspectorState();
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => setChatDisplay({}));

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetInspectorState();
  setHeaderState({ inspector: false, pullRequest: null });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const noop = () => undefined;
let paneWidth = 0;
// The running line's counts call this (App.tsx `openAgents` / `openCommands`).
let reveal: ((section: "subagents" | "tasks") => void) | undefined;

/// The pane's pieces as App.tsx places them: the toggle last in the header's tools, the Inspector
/// beside the chat column in the pane's shell.
function Pane({ snapshot, onOpenOutput }: { snapshot: AcpmuxSnapshot; onOpenOutput: (path: string) => void }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const inspector = useChatInspector({ snapshot, machineName: "Studio", shell, onOpenOutput });
  reveal = inspector.reveal;
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) {
          Object.defineProperty(element, "clientWidth", { configurable: true, get: () => paneWidth });
          setShell(element);
        }
      }}
    >
      <div className="acpmux-main">
        <header className="acpmux-header">
          <ChatHeaderTools
            onTerminal={noop}
            onBrowser={noop}
            summary={null as ReactNode}
            menu={() => []}
            inspector={inspector.button}
          />
        </header>
      </div>
      {inspector.panel}
    </section>
  );
}

const CWD = "/Users/you/src/atlas-web";
const edited = (path: string, oldText: string | undefined, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, oldText, newText }] });

const localChat = chat([
  activity([edited("src/fetch.ts", "a\n", "a\nb\n"), edited("src/retry.ts", undefined, "x\ny\nz\n")], 3),
]);

async function render(container: HTMLElement, snapshot: AcpmuxSnapshot, opened: string[] = []) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Pane snapshot={snapshot} onOpenOutput={(path) => opened.push(path)} />);
  });
  return opened;
}

const toggle = (container: HTMLElement) =>
  container.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Inspector"]');
const panel = (container: HTMLElement) => container.querySelector<HTMLElement>("aside.acpmux-inspector");
const section = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLElement>(`section.acpmux-inspector-section[data-section="${id}"]`);
const sectionIds = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("section.acpmux-inspector-section")].map(
    (element) => element.dataset.section,
  );
const meta = (element: HTMLElement | null) => element?.querySelector(".acpmux-inspector-section__meta")?.textContent;
const head = (element: HTMLElement) => element.querySelector<HTMLElement>("button.ui-disclosure-trigger")!;
const click = (element: HTMLElement) => act(async () => element.click());

test("the Inspector opens with a first chat: its environment, context use and outputs; the toggle closes it", async () => {
  const container = installDom(true);
  const opened = await render(container, localChat);
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("true");
  expect(panel(container)).not.toBeNull();
  // The sections in order; ones with nothing to show (no MCP servers, pull requests, processes or
  // subagents) are left out.
  expect(sectionIds(container)).toEqual(["environment", "context", "outputs"]);

  // Environment: this Mac by its name, never "This computer"; the folder with its parent
  // home-abbreviated and its full path on hover; the branch.
  const rows = [...section(container, "environment")!.querySelectorAll<HTMLElement>(".acpmux-inspector-row")];
  expect(rows[0]!.textContent).toBe("Studio");
  expect(rows[0]!.dataset.machine).toBe("local");
  expect(rows[1]!.textContent).toContain("atlas-web");
  expect(rows[1]!.textContent).toContain("~/src");
  expect(rows[1]!.getAttribute("title")).toBe(CWD);
  expect(rows.map((row) => row.textContent)).toContain("main");

  // Context: 48K of 200K is 24% with a bar, folded until asked; then the tokens.
  const context = section(container, "context")!;
  expect(meta(context)).toContain("24%");
  expect(context.querySelector(".acpmux-inspector-meter")).not.toBeNull();
  expect(context.textContent).not.toContain("tokens");
  await click(head(context));
  expect(section(container, "context")!.textContent).toMatch(/48K of 200K tokens/);

  // Outputs: the changed and the created file, each opening its diff by path.
  const files = [...section(container, "outputs")!.querySelectorAll<HTMLButtonElement>("button.acpmux-inspector-row")];
  expect(files.map((file) => file.querySelector(".acpmux-inspector-row__name")?.textContent)).toEqual([
    "fetch.ts",
    "retry.ts",
  ]);
  expect(files[1]!.textContent).toContain("+3");
  await click(files[1]!);
  expect(opened).toEqual([`${CWD}/src/retry.ts`]);

  // The toggle closes it, and that is remembered.
  await click(toggle(container)!);
  expect(panel(container)).toBeNull();
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("false");
  expect(inspectorState().open).toBe(false);
});

test("open, closed, folds and width hold in every chat pane, following another pane's change", async () => {
  const container = installDom(true);
  await render(container, localChat);
  await click(head(section(container, "context")!));
  await click(toggle(container)!);
  // Another chat tab mounts closed, with Context still open from the first.
  await act(async () => root!.unmount());
  root = undefined;
  await render(container, localChat);
  expect(panel(container)).toBeNull();
  await click(toggle(container)!);
  expect(section(container, "context")!.textContent).toMatch(/48K of 200K tokens/);
  expect(inspectorState().sections.context).toBe(true);

  // Another pane closes it: this one follows its storage event.
  await act(async () => {
    localStorage.setItem("cmux.agentPane.inspector.open", "0");
    window.dispatchEvent(new StorageEvent("storage", { key: "cmux.agentPane.inspector.open" }));
  });
  expect(panel(container)).toBeNull();
});

test("a cloud session names its host; no usage reads a dash; nothing produced says so", async () => {
  const container = installDom(true);
  const base = chat([]);
  await render(container, {
    ...base,
    summary: { ...base.summary!, host: "build-01", hostKind: "cloud", usage: undefined },
  });
  const machine = section(container, "environment")!.querySelector<HTMLElement>(".acpmux-inspector-row")!;
  expect(machine.textContent).toBe("build-01");
  expect(machine.dataset.machine).toBe("cloud");
  const context = section(container, "context")!;
  expect(meta(context)).toBe("—");
  // Nothing to fold without usage.
  expect(context.querySelector("button")).toBeNull();
  expect(section(container, "outputs")!.textContent).toContain("Nothing produced yet");
});

test("with the Debug toggle off there is no toggle button and no Inspector", async () => {
  const container = installDom(false);
  await render(container, localChat);
  expect(toggle(container)).toBeNull();
  expect(panel(container)).toBeNull();
  // The running line's counts fall back to the summary card.
  expect(reveal).toBeUndefined();
});

test("the running line's counts open a closed Inspector with Subagents or Background tasks unfolded", async () => {
  const container = installDom(true);
  await render(container, localChat);
  await click(toggle(container)!);
  await act(async () => {
    setInspectorSection("tasks", false);
    setInspectorSection("subagents", false);
  });
  expect(panel(container)).toBeNull();
  await act(async () => reveal!("tasks"));
  expect(panel(container)).not.toBeNull();
  expect(inspectorState().open).toBe(true);
  expect(inspectorState().sections.tasks).toBe(true);
  expect(inspectorState().sections.subagents).toBe(false);
  await act(async () => reveal!("subagents"));
  expect(inspectorState().sections.subagents).toBe(true);
});

test("it pushes the chat aside unless the pane is too narrow for the chat, or Settings says Overlay", async () => {
  expect(pushes("push", 0, 320)).toBe(true);
  expect(pushes("push", 320 + PUSH_MIN_CHAT, 320)).toBe(true);
  expect(pushes("push", 320 + PUSH_MIN_CHAT - 1, 320)).toBe(false);
  expect(pushes("overlay", 2000, 320)).toBe(false);

  const container = installDom(true);
  paneWidth = 1200;
  await render(container, localChat);
  expect(panel(container)?.dataset.placement).toBe("push");
  expect(panel(container)?.style.width).toBe("320px");
  // A narrow pane: it lies over the chat instead.
  await act(async () => {
    paneWidth = 600;
    for (const observer of observers) observer();
  });
  expect(panel(container)?.dataset.placement).toBe("overlay");
  // Settings > Agent Chat > Inspector: Overlay, even in a wide pane.
  await act(async () => {
    paneWidth = 1200;
    for (const observer of observers) observer();
    setChatDisplay({ [INSPECTOR_PLACEMENT_KEY]: "overlay" });
  });
  expect(panel(container)?.dataset.placement).toBe("overlay");
  paneWidth = 0;
});

test("an output whose diff split leaves no room to push the chat closes the Inspector until the toggle", async () => {
  const container = installDom(true);
  paneWidth = 1200;
  const opened = await render(container, localChat);
  const files = [...section(container, "outputs")!.querySelectorAll<HTMLButtonElement>("button.acpmux-inspector-row")];
  await click(files[0]!);
  expect(opened).toEqual([`${CWD}/src/fetch.ts`]);
  // The diff opens beside the chat and halves the pane.
  await act(async () => {
    paneWidth = 600;
    for (const observer of observers) observer();
  });
  expect(panel(container)).toBeNull();
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("false");
  // Not remembered as closed: the next chat still opens it, and the toggle brings it back here.
  expect(inspectorState().open).toBe(true);
  await click(toggle(container)!);
  expect(panel(container)).not.toBeNull();
  paneWidth = 0;
});

test("Connectors counts the connected servers and the ones to reconnect; a harness that reports none has no section", async () => {
  const container = installDom(true);
  const base = chat([]);
  await render(container, {
    ...base,
    summary: {
      ...base.summary!,
      mcpServers: [
        { name: "github", status: "connected" },
        { name: "linear", status: "failed" },
        { name: "sentry", status: "pending" },
      ],
    },
  });
  expect(sectionIds(container)).toEqual(["environment", "context", "connectors", "outputs"]);
  const connectors = section(container, "connectors")!;
  expect(meta(connectors)).toBe("1 connected · 1 to reconnect");
  expect(connectors.querySelector(".acpmux-inspector-row")).toBeNull();
  await click(head(connectors));
  const rows = [...section(container, "connectors")!.querySelectorAll(".acpmux-inspector-row")].map(
    (row) => row.textContent,
  );
  expect(rows).toEqual(["github", "linearNeeds reconnect", "sentryConnecting"]);

  await render(container, base);
  expect(section(container, "connectors")).toBeNull();
});

/// A `gh pr create` the agent ran, printing its pull request's URL.
const opened = (number: number, title: string) =>
  tool("gh pr create", "execute", "completed", {
    command: `gh pr create --title "${title}" --body x`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });
const ran = (command: string, endedAt?: number) =>
  tool(command, "execute", "completed", { command, output: "", exitCode: 0, ...(endedAt ? { endedAt } : {}) });

test("Changes lists the pull requests the chat opened or touched, newest first, every one of them", async () => {
  const container = installDom(true);
  await render(container, localChat);
  // No pull request yet: no section, not an empty one.
  expect(section(container, "changes")).toBeNull();

  // The folder's pull request, as the App pushes it: two checks failing.
  setHeaderState({
    pullRequest: {
      url: "https://github.com/acme/atlas-web/pull/12",
      number: 12,
      title: "Retry the fetch helper",
      state: "open",
      checks: { state: "failing", passed: 3, total: 5 },
      checkList: [
        { name: "lint", state: "failed" },
        { name: "test", state: "failed" },
        { name: "build", state: "passed" },
      ],
    },
  });
  await render(
    container,
    chat([
      activity([opened(12, "Retry the fetch helper")], 5),
      activity([ran("gh pr merge https://github.com/acme/billing/pull/7 --squash")], 1),
      activity(
        [1, 2, 3, 4, 5, 6, 7].map((number) => opened(20 + number, `Change ${number}`)),
        2,
      ),
    ]),
  );
  expect(sectionIds(container)).toEqual(["environment", "context", "changes", "outputs"]);
  const changes = section(container, "changes")!;
  expect(meta(changes)).toBe("9");
  const rows = [...changes.querySelectorAll<HTMLElement>("li.acpmux-inspector-pr")];
  // All nine: the list scrolls; nothing waits behind a "Show more".
  expect(rows).toHaveLength(9);
  expect(changes.querySelector(".acpmux-inspector-scroll, .acpmux-inspector-scroll *")).not.toBeNull();
  expect(changes.textContent).not.toContain("Show");
  const links = rows.map((row) => row.querySelector<HTMLAnchorElement>("a.acpmux-inspector-pr__link")!);
  expect(links[0]!.getAttribute("href")).toBe("https://github.com/acme/atlas-web/pull/27");
  // The one it only merged, by URL in another repository, is there with its state.
  expect(links[7]!.getAttribute("href")).toBe("https://github.com/acme/billing/pull/7");
  expect(rows[7]!.dataset.state).toBe("merged");
  expect(links[7]!.querySelector(".acpmux-inspector-pr__ref")?.textContent).toBe("billing #7");
  const folder = rows[8]!;
  expect(folder.querySelector(".acpmux-inspector-pr__title")?.textContent).toBe("Retry the fetch helper");
  // Only the pull request whose checks the App reads says how they stand: how many fail.
  expect(rows[0]!.querySelector(".acpmux-inspector-pr__checks")).toBeNull();
  expect(folder.querySelector(".acpmux-inspector-pr__checks")?.textContent).toBe("2 failing");
  // Each row has its ⋯ menu.
  expect(folder.querySelector("button.acpmux-inspector-pr__more")?.getAttribute("aria-label")).toBe(
    "More for acme/atlas-web#12",
  );
});

test("a pull request row shows its line counts, the failing checks already on base dimmed, and its owner", async () => {
  const container = installDom(true);
  const url = "https://github.com/acme/atlas-web/pull/12";
  const made = sessionSummary(chat([activity([opened(12, "Retry")], 1)]).rows);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ChatInspector
        made={made}
        statuses={{
          [url]: {
            additions: 120,
            deletions: 30,
            breakdown: { code: { additions: 100, deletions: 30 }, tests: { additions: 20, deletions: 0 } },
            checks: "failing",
            failing: 3,
            failingOnBase: 2,
            owner: "inspector",
          },
        }}
      />,
    );
  });
  const row = section(container, "changes")!.querySelector<HTMLElement>("li.acpmux-inspector-pr")!;
  expect(row.querySelector(".acpmux-inspector-pr__counts")?.textContent).toBe("+120-30");
  expect(row.querySelector(".acpmux-inspector-pr__checks")?.textContent).toBe("3 failing (2 already on base)");
  expect(row.querySelector(".acpmux-inspector-pr__base")?.textContent).toBe(" (2 already on base)");
  expect(row.querySelector(".acpmux-inspector-pr__owner")?.textContent).toBe("Owner inspector");
});

test("a pull request the chat closed shows Closed until the App reads it again after the close", async () => {
  const container = installDom(true);
  const url = "https://github.com/acme/atlas-web/pull/13";
  const status = (state: string, at: number) => {
    setSystemTime(new Date(at));
    setHeaderState({
      pullRequest: { url, number: 13, title: "Retry", state, checks: { state: "failing", passed: 3, total: 5 } },
    });
  };
  // The App read it open before the chat closed it at 2000.
  status("open", 1000);
  const closedChat = chat([activity([opened(13, "Retry"), ran("gh pr close 13", 2000)], 2)]);
  try {
    await render(container, closedChat);
    const row = () => section(container, "changes")!.querySelector<HTMLElement>("li.acpmux-inspector-pr")!;
    // That older open read doesn't undo the close.
    expect(row().dataset.state).toBe("closed");
    expect(row().querySelector(".acpmux-inspector-pr__checks")).toBeNull();

    // Later reads: closed, then someone reopened it.
    status("closed", 3000);
    await render(container, closedChat);
    expect(row().dataset.state).toBe("closed");
    status("open", 4000);
    await render(container, closedChat);
    expect(row().dataset.state).toBe("open");
    expect(row().querySelector(".acpmux-inspector-pr__checks")?.textContent).toBe("Failing");

    // Hiding and showing the Inspector keeps the reopen.
    await click(toggle(container)!);
    await click(toggle(container)!);
    expect(row().dataset.state).toBe("open");
  } finally {
    setSystemTime();
  }
});

const subagent = (index: number, state: string): Subagent => ({
  id: `agent-${index}`,
  parent: null,
  name: `Agent ${index}`,
  state,
  startedAt: index,
});

test("Subagents is one avatar row with live counts that opens into the list", async () => {
  const container = installDom(true);
  const agents = [
    ...[0, 1, 2].map((index) => subagent(index, "running")),
    ...Array.from({ length: 40 }, (_, index) => subagent(3 + index, "completed")),
  ];
  const shown: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<ChatInspector agents={agents} onOpenSubagent={(id) => shown.push(id)} />);
  });
  const subagents = section(container, "subagents")!;
  expect(meta(subagents)).toBe("3 running · 40 done");
  const row = subagents.querySelector<HTMLButtonElement>("button.acpmux-inspector-avatars")!;
  expect(row.getAttribute("aria-label")).toBe("Show 43 subagents");
  expect(row.getAttribute("aria-expanded")).toBe("false");
  // Eight avatars, the running ones first, then "+35".
  expect(row.querySelectorAll(".acpmux-inspector-avatars__stack > *")).toHaveLength(8);
  expect(row.querySelector(".acpmux-inspector-avatars__more")?.textContent).toBe("+35");
  expect(subagents.querySelector(".acpmux-inspector-subagents__list")).toBeNull();
  await click(row);
  expect(row.getAttribute("aria-expanded")).toBe("true");
  expect(row.getAttribute("aria-label")).toBe("Hide subagents");
  expect(subagents.querySelector(".acpmux-inspector-subagents__list")).not.toBeNull();
});
