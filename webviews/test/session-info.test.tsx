// l10n-allow-file: test fixture chat titles, not shipped UI.
// Session Info (Debug Settings `agent.inspector`, on by default; Claude Code desktop's session
// panel): with the flag on, the header's top-right toggle opens a
// panel at the right of the chat with where it runs (Environment), how much of the context window
// it used (Context), its MCP servers (Connectors), the pull requests it opened or touched
// (Changes), its subagents and the chats its agent started, a Cloud VM's included, its background
// commands and what it produced (Outputs). It is open by
// default, stays open (or closed) in each chat pane on its own, floats outside the chat's layout so it never
// moves or reflows the chat (Settings Push always takes a column), hides a section with nothing in it, and shows five pull
// requests under Changes and five running subagents, each then Show more (Claude Code desktop's).
import { readFileSync } from "node:fs";

import { afterEach, beforeEach, expect, setSystemTime, spyOn, test } from "bun:test";
import { act, useMemo, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import { SESSION_INFO_PLACEMENT_KEY, setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { resetPullRequestStore } from "../src/agent-session/acpmux/chips/pullRequestStore";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { resetChangesStatuses } from "../src/agent-session/acpmux/session-info/changesStatus";
import {
  SessionInfo,
  sessionInfoTopOffset,
  sessionInfoOverChat,
  pushedWidth,
  pushes,
  useSessionInfo,
} from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  SESSION_INFO_WIDTH,
  sessionInfoState,
  resetSessionInfoState,
  setSessionInfoSection,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";
import {
  spawnedSessions,
  startedSessions,
  type StartedSession,
} from "../src/agent-session/acpmux/started/startedSessions";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import * as subagentGroup from "../src/agent-session/acpmux/subagents/SubagentGroup";
import * as tones from "../src/agent-session/acpmux/subagents/agentTones";
import { openSourceFile } from "../src/agent-session/acpmux/session-info/SourcesSection";
import { NativeError } from "../src/agent-session/acpmux/nativeError";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, assistant, chat, tool } from "../src/gallery/fixtures/acpmux";
import { withCloudMachineSummary } from "../src/agent-session/acpmux/cloudSummary";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

/// ResizeObservers the page made, so a test can resize the pane.
let observers: (() => void)[] = [];

function installDom(sessionInfo: boolean): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  // The App pushes Debug Settings `agent.inspector` with the header state.
  setHeaderState({ inspector: sessionInfo });
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
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => setChatDisplay({}));

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
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

/// The pane's pieces as App.tsx places them: the toggle last in the header's tools, Session Info
/// beside the chat column in the pane's shell.
function Pane({
  snapshot,
  onOpenOutput,
  sessions,
  onPanelRender,
  rerenderOnScroll = false,
  cloudRepositoryAvailable,
  cloudMachineID,
}: {
  snapshot: AcpmuxSnapshot;
  onOpenOutput: (path: string) => void;
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  onPanelRender?: () => void;
  rerenderOnScroll?: boolean;
  cloudRepositoryAvailable?: boolean;
  cloudMachineID?: string;
}) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const [scrollFrame, setScrollFrame] = useState(0);
  const sessionInfoSnapshot = useMemo(
    () => ({ ...snapshot, summary: withCloudMachineSummary(snapshot.summary, cloudMachineID) }),
    [snapshot, cloudMachineID],
  );
  const sessionInfo = useSessionInfo({
    snapshot: sessionInfoSnapshot,
    machineName: "Studio",
    cloudRepositoryAvailable,
    shell,
    onOpenOutput,
    onRender: onPanelRender,
    sessions,
  });
  reveal = sessionInfo.reveal;
  return (
    <section
      className="acpmux-shell"
      data-scroll-frame={scrollFrame}
      onScroll={rerenderOnScroll ? () => setScrollFrame((frame) => frame + 1) : undefined}
      ref={(element) => {
        if (element && element !== shell) {
          Object.defineProperty(element, "clientWidth", {
            configurable: true,
            get: () => paneWidth,
          });
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
            sessionInfo={sessionInfo.button}
          />
        </header>
      </div>
      {sessionInfo.panel}
    </section>
  );
}

const CWD = "/Users/you/src/atlas-web";
const edited = (path: string, oldText: string | undefined, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", {
    diffs: [{ path: `${CWD}/${path}`, oldText, newText }],
  });

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
  container.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Session Info"]');
const panel = (container: HTMLElement) => container.querySelector<HTMLElement>("aside.acpmux-session-info");
const section = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLElement>(`section.acpmux-session-info-section[data-section="${id}"]`);
const sectionIds = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("section.acpmux-session-info-section")].map(
    (element) => element.dataset.section,
  );
const meta = (element: HTMLElement | null) => element?.querySelector(".acpmux-session-info-section__meta")?.textContent;
const head = (element: HTMLElement) => element.querySelector<HTMLElement>("button.ui-disclosure-trigger")!;
const click = (element: HTMLElement) => act(async () => element.click());
test("Session Info Sources navigate mixed targets and preserve expansion during streaming", async () => {
  const container = installDom(true);
  const sources = [
    { label: "PR", kind: "pullRequest" as const, url: "https://github.com/acme/app/pull/1" },
    { label: "Issue", kind: "issue" as const, url: "https://github.com/acme/app/issues/2" },
    { label: "Docs", kind: "url" as const, url: "https://example.test/docs" },
    { label: "src/../app.ts", kind: "file" as const },
    { label: "/project/.claude/worktrees/a/README.md", kind: "file" as const },
    { label: "../../../README.md", kind: "file" as const },
    { label: "/shared/README.md", kind: "file" as const },
    { label: "/project/.claude/worktrees/another/file", kind: "file" as const },
  ];
  const urls: string[] = [];
  const files: string[] = [];
  const draw = async (rows: AcpmuxSnapshot["rows"] = []) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <SessionInfo
          summary={{ sessionId: "chat", cwd: "/project/.claude/worktrees/a" }}
          rows={rows}
          made={{ outputs: [], pullRequests: [], scheduled: [], sources }}
          onOpenUrl={(url) => urls.push(url)}
          onOpenSourceFile={(path) => files.push(path)}
        />,
      );
    });
  await draw();
  const list = () => container.querySelectorAll("[data-section=sources] li");
  const fold = () => container.querySelector<HTMLButtonElement>(".acpmux-session-info-sources-fold")!;
  expect(list()).toHaveLength(5);
  for (const target of container.querySelectorAll<HTMLElement>("ul[data-section=sources] :is(a,button)"))
    await click(target);
  expect(urls).toEqual(sources.slice(0, 3).map((source) => source.url!));
  expect(files).toEqual(["/project/.claude/worktrees/a/app.ts", "/project/.claude/worktrees/a/README.md"]);
  await click(fold());
  expect(list()).toHaveLength(8);
  expect(container.querySelectorAll("ul[data-section=sources] button")).toHaveLength(2);
  expect(fold().textContent).toContain("Show fewer");
  await draw([{ ...assistant("stream", 1), streaming: true }]);
  expect(list()).toHaveLength(8);
  await click(fold());
  expect(list()).toHaveLength(5);
});
test("file Sources use native editor fallback and show a transient failure", async () => {
  const container = installDom(true);
  const calls: unknown[] = [];
  const native = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    if (params.where === "tab" || params.path === "/project/missing")
      throw new NativeError({ code: "transport.path_invalid", userMessage: "Could not open file" });
  };
  const sources = ["page.html", "icon.svg", "Dockerfile", "missing"].map((label) => ({ label, kind: "file" as const }));
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfo
        summary={{ sessionId: "chat", cwd: "/project" }}
        made={{ outputs: [], pullRequests: [], scheduled: [], sources }}
        onOpenSourceFile={(path) => openSourceFile(path, native)}
      />,
    );
  });
  let expire: (() => void) | undefined;
  const timer = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void) => {
    expire = callback;
    return 1;
  }) as typeof setTimeout);
  try {
    for (const button of container.querySelectorAll<HTMLButtonElement>("ul[data-section=sources] button"))
      await click(button);
    for (const { label } of sources) {
      const expected = ["tab", "editor"].map((where) => ["file.open", { path: `/project/${label}`, where }]);
      expect(calls.splice(0, 2)).toEqual(expected);
    }
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Could not open file");
    await act(async () => expire!());
    expect(container.querySelector('[role="alert"]')).toBeNull();
  } finally {
    timer.mockRestore();
  }
});

test("Session Info starts right under the header: no row for a machine and folder label", () => {
  expect(sessionInfoTopOffset(0)).toBe("var(--acpmux-header-height, 28px)");
  expect(sessionInfoTopOffset(28)).toBe("28px");
});

test("Session Info does not render when the transcript scrolls", async () => {
  const container = installDom(true);
  let renders = 0;
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane snapshot={localChat} onOpenOutput={noop} rerenderOnScroll onPanelRender={() => renders++} />);
  });
  const beforeScroll = renders;
  const shell = container.querySelector<HTMLElement>(".acpmux-shell")!;
  for (let frame = 0; frame < 20; frame++) {
    await act(async () => {
      shell.dispatchEvent(new dom!.window.Event("scroll", { bubbles: true }));
    });
  }
  expect(shell.dataset.scrollFrame).toBe("20");
  expect(renders).toBe(beforeScroll);
});

test("Session Info opens with a first chat: its environment, context use and outputs; the toggle closes it", async () => {
  const container = installDom(true);
  const opened = await render(container, localChat);
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("true");
  expect(panel(container)).not.toBeNull();
  expect(panel(container)?.querySelector(".acpmux-session-info__head")).toBeNull();
  // No x and no band over the first row: the toggle and Esc close it (Leo, 2026-10-24).
  expect(panel(container)?.querySelector(".acpmux-session-info__close")).toBeNull();
  // The sections in order; ones with nothing to show (no MCP servers, pull requests, processes or
  // subagents) are left out.
  expect(sectionIds(container)).toEqual(["environment", "context", "outputs"]);

  // Environment: this Mac by its name, never "This computer"; the project by its name, its full path
  // only on hover; the branch.
  const rows = [...section(container, "environment")!.querySelectorAll<HTMLElement>(".acpmux-session-info-row")];
  // The machine row says where the chat runs in words, not only by name (Leo, 2026-10-31).
  expect(rows[0]!.querySelector(".acpmux-session-info-row__name")?.textContent).toBe("Studio");
  expect(rows[0]!.querySelector("[data-machine-kind]")?.textContent).toBe(translate("composer.envLocal"));
  expect(rows[0]!.dataset.machine).toBe("local");
  expect(rows[1]!.textContent).toBe("atlas-web");
  expect(rows[1]!.getAttribute("title")).toBe(CWD);
  expect(rows.map((row) => row.textContent)).toContain("main");

  // Context: 48K of 200K is 24% with a bar, open from the start (Leo, 2026-11-01: "context tho is
  // pretty good i think to keep expanded by default?"): as Claude Code desktop's, the percent used
  // with the tokens, a bar, and the used and free parts with their shares.
  const open = section(container, "context")!;
  expect(meta(open)).toContain("24%");
  expect(open.querySelector(".acpmux-session-info-meter")).not.toBeNull();
  expect(open.querySelector(".acpmux-session-info-context__total")?.textContent).toBe("24% used48K / 200K");
  const bar = open.querySelector<HTMLElement>('.acpmux-session-info-context__bar [data-part="used"]');
  expect(bar?.style.width).toBe("24%");
  const parts = [...open.querySelectorAll<HTMLElement>(".acpmux-session-info-row[data-part]")];
  expect(parts.map((row) => row.textContent)).toEqual(["Used48K24%", "Free space152K76%"]);

  // Outputs: the changed and the created file, each opening its diff by path.
  const files = [
    ...section(container, "outputs")!.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row"),
  ];
  expect(files.map((file) => file.querySelector(".acpmux-session-info-row__name")?.textContent)).toEqual([
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
  expect(sessionInfoState().open).toBe(false);
});

test("Session Info derives Cloud from the host handshake when the summary has no kind or peer", async () => {
  const container = installDom(true);
  const summaryWithoutMachineKind = { ...chat([]).summary! };
  delete summaryWithoutMachineKind.hostKind;
  delete summaryWithoutMachineKind.peer;
  const realCloudShape: AcpmuxSnapshot = {
    ...chat([]),
    summary: { ...summaryWithoutMachineKind, sessionId: "cloud-session", host: "cloud-01" },
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <Pane snapshot={realCloudShape} onOpenOutput={noop} cloudMachineID="cloud-machine-id" cloudRepositoryAvailable />,
    );
  });
  const environment = section(container, "environment")!;
  expect(environment.querySelector("li[data-machine]")?.textContent).toContain("cloud-01");
  expect(environment.textContent).toContain("Default");
  expect(environment.textContent).toContain("Add repository…");

  await act(async () => {
    root!.render(<Pane snapshot={realCloudShape} onOpenOutput={noop} cloudRepositoryAvailable={false} />);
  });
  expect(section(container, "environment")?.textContent).not.toContain("Add repository…");
  expect(section(container, "environment")?.textContent).not.toContain("Default");
});

test("Session Info keeps a summary without a Cloud machine id local", async () => {
  const container = installDom(true);
  const summaryWithoutMachineKind = { ...chat([]).summary! };
  delete summaryWithoutMachineKind.hostKind;
  delete summaryWithoutMachineKind.peer;
  const localShape: AcpmuxSnapshot = {
    ...chat([]),
    summary: { ...summaryWithoutMachineKind, sessionId: "local-session", host: "Studio" },
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane snapshot={localShape} onOpenOutput={noop} cloudRepositoryAvailable />);
  });
  const environment = section(container, "environment")!;
  expect(environment.querySelector<HTMLElement>("li[data-machine]")?.dataset.machine).toBe("local");
  expect(environment.querySelector("li[data-machine]")?.textContent).toContain("Studio");
  expect(environment.textContent).not.toContain("Add repository…");
  expect(environment.textContent).not.toContain("Default");
});

test("open, closed, folds and width are this pane's, and another pane's change never reaches it", async () => {
  // Leo, 2026-10-25: "it opens and closes on the other side too when you do one... they should all be
  // individual per pane".
  const container = installDom(true);
  await render(container, localChat);
  await click(head(section(container, "context")!));
  await click(toggle(container)!);
  // The same pane drawn again (a chat shown again) keeps its state: closed, Context folded.
  await act(async () => root!.unmount());
  root = undefined;
  await render(container, localChat);
  expect(panel(container)).toBeNull();
  await click(toggle(container)!);
  expect(section(container, "context")!.textContent).not.toContain("48K / 200K");
  expect(sessionInfoState().sections.context).toBe(false);
  await click(toggle(container)!);

  // Another pane opens its own: this one stays closed.
  await act(async () => {
    localStorage.setItem("cmux.agentPane.inspector.open", "1");
    window.dispatchEvent(new StorageEvent("storage", { key: "cmux.agentPane.inspector.open" }));
  });
  expect(panel(container)).toBeNull();
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("false");
});

test("a pane switched to another chat shows that chat's Session Info at once, never playing the last one out", async () => {
  const container = installDom(true);
  const chatB = { ...localChat, sessionId: "chat-b" };
  // Chat B was left closed, chat A open.
  await render(container, chatB);
  await click(toggle(container)!);
  expect(panel(container)).toBeNull();
  await render(container, localChat);
  await click(toggle(container)!);
  expect(panel(container)).not.toBeNull();
  // Every phase change of a Session Info panel while the pane switches to chat B (chat A's panel
  // turning to `leaving` is the last chat's panel playing out over chat B).
  const phases: string[] = [];
  const observer = new MutationObserver((records) => {
    for (const record of records)
      phases.push(`${record.oldValue} -> ${(record.target as HTMLElement).getAttribute("data-presence")}`);
  });
  observer.observe(container, {
    subtree: true,
    attributeOldValue: true,
    attributeFilter: ["data-presence"],
  });
  await render(container, chatB);
  await act(async () => undefined);
  phases.push(...observer.takeRecords().map((record) => `${record.oldValue} ->`));
  observer.disconnect();
  expect({
    phases,
    panel: panel(container),
    pressed: toggle(container)?.getAttribute("aria-pressed"),
  }).toEqual({
    phases: [],
    panel: null,
    pressed: "false",
  });
  // And back to chat A: open again, as it was left.
  await render(container, localChat);
  expect(panel(container)).not.toBeNull();
});

test("a cloud session names its host; no usage and nothing produced have no sections", async () => {
  const container = installDom(true);
  const base = chat([]);
  await render(container, {
    ...base,
    summary: { ...base.summary!, host: "build-01", hostKind: "cloud", usage: undefined },
  });
  const machine = section(container, "environment")!.querySelector<HTMLElement>(".acpmux-session-info-row")!;
  expect(machine.querySelector(".acpmux-session-info-row__name")?.textContent).toBe("build-01");
  expect(machine.querySelector("[data-machine-kind]")?.textContent).toBe(translate("composer.cloud"));
  expect(machine.dataset.machine).toBe("cloud");
  expect(section(container, "context")).toBeNull();
  expect(section(container, "outputs")).toBeNull();
});

test("with the Debug toggle off there is no toggle button and no Session Info", async () => {
  const container = installDom(false);
  await render(container, localChat);
  expect(toggle(container)).toBeNull();
  expect(panel(container)).toBeNull();
  // The running line's counts fall back to the summary card.
  expect(reveal).toBeUndefined();
});

test("the running line's counts open a closed Session Info with Subagents or Background tasks unfolded", async () => {
  const container = installDom(true);
  await render(container, localChat);
  await click(toggle(container)!);
  await act(async () => {
    setSessionInfoSection("tasks", false);
    setSessionInfoSection("subagents", false);
  });
  expect(panel(container)).toBeNull();
  await act(async () => reveal!("tasks"));
  expect(panel(container)).not.toBeNull();
  expect(sessionInfoState().open).toBe(true);
  expect(sessionInfoState().sections.tasks).toBe(true);
  expect(sessionInfoState().sections.subagents).toBe(false);
  await act(async () => reveal!("subagents"));
  expect(sessionInfoState().sections.subagents).toBe(true);
});

test("it floats outside the chat's layout in every pane, and pushes only with Settings Push always", async () => {
  // Leo, 2026-10-24: "it was never supposed to be a sidebar; y'all kept doing sidebars".
  expect(pushes("overlay")).toBe(false);
  expect(pushes("push")).toBe(true);
  // Pushed, it narrows to keep a readable chat and its 8px margin, down to its own narrowest width.
  expect(pushedWidth(1200, 320)).toBe(320);
  expect(pushedWidth(720, 320)).toBe(272);
  expect(pushedWidth(500, 320)).toBe(SESSION_INFO_WIDTH.min);
  expect(pushedWidth(0, 320)).toBe(320);

  const container = installDom(true);
  paneWidth = 1600;
  await render(container, localChat);
  // A wide pane: floating in the gutter, so opening it never reflows the chat.
  expect(panel(container)?.dataset.placement).toBe("overlay");
  expect(panel(container)?.style.width).toBe("320px");
  // Narrower panes, where it used to take a column: it still floats, at its own width.
  for (const width of [1200, 720]) {
    await act(async () => {
      paneWidth = width;
      for (const observer of observers) observer();
    });
    expect(panel(container)?.dataset.placement).toBe("overlay");
    expect(panel(container)?.style.width).toBe("320px");
  }
  // Settings > Agent Chat > Session Info: Push, even in a wide pane.
  await act(async () => {
    paneWidth = 1600;
    for (const observer of observers) observer();
    setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "push" });
  });
  expect(panel(container)?.dataset.placement).toBe("push");
  // Back to the default.
  await act(async () => setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "overlay" }));
  expect(panel(container)?.dataset.placement).toBe("overlay");
  paneWidth = 0;
});

test("the panel lies over the chat only when the right gutter cannot hold it; the chat never moves for it", () => {
  // Leo, 2026-10-29: "it's not supposed to be a fucking sidebar that pushes the fucking layout". A
  // 1600px pane's 400px gutter holds 320px and its two 8px margins: it floats beside the column.
  expect(sessionInfoOverChat(1600, 320)).toBe(false);
  // 1200px: a 225px gutter cannot hold it, and the column stays put: it floats over the chat.
  expect(sessionInfoOverChat(1200, 320)).toBe(true);
  expect(sessionInfoOverChat(720, 320)).toBe(true);
  // Unmeasured, it is nowhere yet.
  expect(sessionInfoOverChat(0, 320)).toBe(false);
  // A wider column (the user's Text Width) leaves a 250px gutter.
  expect(sessionInfoOverChat(1600, 320, { min: 720, max: 1100, share: 1, prose: Infinity })).toBe(true);
  // A handoff review's 760px form: measured against the form's own gutter.
  expect(sessionInfoOverChat(1600, 320, undefined, true)).toBe(false);
  expect(sessionInfoOverChat(1200, 320, undefined, true)).toBe(true);
});

test("opening Session Info moves no part of the chat", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/session-info/sessionInfo.css", import.meta.url),
    "utf8",
  );
  const source = readFileSync(
    new URL("../src/agent-session/acpmux/session-info/SessionInfo.tsx", import.meta.url),
    "utf8",
  );
  expect(css).not.toContain("--acpmux-chat-shift");
  expect(source).not.toContain("--acpmux-chat-shift");
});

test("an output whose diff split leaves no room to push the chat closes Session Info until the toggle", async () => {
  setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "push" });
  const container = installDom(true);
  paneWidth = 1200;
  const opened = await render(container, localChat);
  const files = [
    ...section(container, "outputs")!.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row"),
  ];
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
  expect(sessionInfoState().open).toBe(true);
  await click(toggle(container)!);
  expect(panel(container)).not.toBeNull();
  paneWidth = 0;
});

test("floating, an output's diff split beside the chat leaves Session Info open", async () => {
  setChatDisplay({ [SESSION_INFO_PLACEMENT_KEY]: "overlay" });
  const container = installDom(true);
  paneWidth = 1200;
  await render(container, localChat);
  const files = [
    ...section(container, "outputs")!.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row"),
  ];
  await click(files[0]!);
  // The diff opens beside the chat and halves the pane: the floating panel takes no room, so it stays.
  await act(async () => {
    paneWidth = 600;
    for (const observer of observers) observer();
  });
  expect(panel(container)?.dataset.placement).toBe("overlay");
  expect(toggle(container)?.getAttribute("aria-pressed")).toBe("true");
  paneWidth = 0;
});

test("Connectors says how many to reconnect, else how many connected; open, each server's status", async () => {
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
  expect(sectionIds(container)).toEqual(["environment", "context", "connectors"]);
  const connectors = section(container, "connectors")!;
  // As Claude Code desktop's head: the servers to reconnect, when any failed.
  expect(meta(connectors)).toBe("1 to reconnect");
  expect(connectors.querySelector(".acpmux-session-info-row")).toBeNull();
  await click(head(connectors));
  const rows = [...section(container, "connectors")!.querySelectorAll(".acpmux-session-info-row")].map(
    (row) => row.textContent,
  );
  expect(rows).toEqual(["githubConnected", "linearNeeds reconnect", "sentryConnecting"]);

  // None failed: how many are connected.
  await render(container, {
    ...base,
    summary: { ...base.summary!, mcpServers: [{ name: "github", status: "connected" }] },
  });
  expect(meta(section(container, "connectors"))).toBe("1 connected");

  // A harness that reports none has no section.
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
  tool(command, "execute", "completed", {
    command,
    output: "",
    exitCode: 0,
    ...(endedAt ? { endedAt } : {}),
  });

test("Changes lists the pull requests the chat opened or touched, open ones first, five then Show more", async () => {
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
  expect(sectionIds(container)).toEqual(["environment", "context", "changes"]);
  const changes = section(container, "changes")!;
  expect(meta(changes)).toBe("9");
  const listed = () => [...changes.querySelectorAll<HTMLElement>("li.acpmux-session-info-pr")];
  // Five, then Show more for the other four.
  expect(listed()).toHaveLength(5);
  await click(changes.querySelector<HTMLButtonElement>("button.acpmux-session-info-pr-fold")!);
  const rows = listed();
  expect(rows).toHaveLength(9);
  const links = rows.map((row) => row.querySelector<HTMLAnchorElement>("a.acpmux-session-info-pr__link")!);
  expect(links[0]!.getAttribute("href")).toBe("https://github.com/acme/atlas-web/pull/27");
  // The one it only merged, by URL in another repository, is there, last, with its state.
  expect(links[8]!.getAttribute("href")).toBe("https://github.com/acme/billing/pull/7");
  expect(rows[8]!.dataset.state).toBe("merged");
  expect(links[8]!.querySelector(".acpmux-session-info-pr__ref")?.textContent).toBe("billing #7");
  const folder = rows[7]!;
  expect(folder.querySelector(".acpmux-session-info-pr__title")?.textContent).toBe("Retry the fetch helper");
  // Only the pull request whose checks the App reads says how they stand: how many fail.
  expect(rows[0]!.querySelector(".acpmux-session-info-pr__checks")).toBeNull();
  expect(folder.querySelector(".acpmux-session-info-pr__checks")?.textContent).toBe("2 failing");
  // Each row has its ⋯ menu.
  expect(folder.querySelector("button.acpmux-session-info-pr__more")?.getAttribute("aria-label")).toBe(
    "More for acme/atlas-web#12",
  );
});

test("Changes reads every pull request's title, state and checks from the App's cache, the issues named like #N left out", async () => {
  const container = installDom(true);
  const hq = "https://github.com/manaflow-ai/cmuxterm-hq/pull/2681";
  const glaeda = "https://github.com/manaflow-ai/glaeda/pull/1546";
  const calls: string[] = [];
  const answer = (url: string, number: number, title: string, state: string, failed: number) => ({
    pullRequest: {
      url,
      number,
      title,
      state,
      review: "",
      mergeable: "",
      additions: 608,
      deletions: 8,
      checks: { state: failed ? "failing" : "passing", passed: 3, total: 3 + failed },
      checkList: Array.from({ length: failed }, (_, index) => ({
        name: `check ${index}`,
        state: "failed",
      })),
    },
    fetchedAt: 1_700_000_000,
    reading: false,
  });
  setChipHost(async (method, params) => {
    calls.push(method);
    if (method !== "pr.inspect") return {};
    if (params.url === hq) return answer(hq, 2681, "Bash scripts keep here-documents", "open", 2);
    if (params.url === glaeda) return answer(glaeda, 1546, "ota: hosts report what they run", "merged", 0);
    // GitHub has no pull request #9: it was an issue.
    return { pullRequest: null, reading: false };
  });
  try {
    await render(
      container,
      chat([
        activity([ran("gh pr update-branch 2681 -R manaflow-ai/cmuxterm-hq")], 3),
        activity([ran("gh pr merge 1546 -R manaflow-ai/glaeda")], 2),
        assistant("Both are in; glaeda #9 is the issue it fixes.", 1),
      ]),
    );
    // The host's answers settle on promises: yield until both rows have their titles.
    for (
      let turn = 0;
      turn < 20 && !/here-documents[\s\S]*hosts report/.test(section(container, "changes")?.textContent ?? "");
      turn++
    )
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    const changes = section(container, "changes")!;
    const rows = [...changes.querySelectorAll<HTMLElement>("li.acpmux-session-info-pr")];
    expect(rows.map((row) => row.querySelector(".acpmux-session-info-pr__title")?.textContent)).toEqual([
      "Bash scripts keep here-documents",
      "ota: hosts report what they run",
    ]);
    expect(rows.map((row) => row.dataset.state)).toEqual(["open", "merged"]);
    expect(rows[0]!.querySelector(".acpmux-session-info-pr__checks")?.textContent).toBe("2 failing");
    expect(rows[0]!.querySelector(".acpmux-diff-counts")?.textContent).toBe("+608-8");
    expect(meta(changes)).toBe("2");
    // The list and the visible rows' hover-card site metadata each register as a batch.
    expect(calls.filter((method) => method === "link.inspect")).toHaveLength(2);
  } finally {
    setChipHost(undefined);
    resetPullRequestStore();
    resetChangesStatuses();
  }
});

test("a folded Changes registers nothing with the host and asks it nothing", async () => {
  const container = installDom(true);
  const calls: string[] = [];
  setChipHost(async (method) => {
    if (method === "link.inspect" || method === "pr.inspect") calls.push(method);
    return method === "pr.inspect" ? { pullRequest: null, reading: true } : {};
  });
  setSessionInfoSection("changes", false);
  try {
    await render(container, chat([activity([opened(31, "Retry the fetch helper")], 2)]));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(section(container, "changes")).not.toBeNull();
    expect(calls).toEqual([]);
    // Opened: the list and row hover-card metadata register, then the host's PR cache.
    await act(async () => setSessionInfoSection("changes", true));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(calls).toEqual(["link.inspect", "link.inspect", "pr.inspect"]);
  } finally {
    setSessionInfoSection("changes", true);
    setChipHost(undefined);
    resetPullRequestStore();
    resetChangesStatuses();
  }
});

test("read-only Sources neither register nor poll with Changes open by default", async () => {
  const container = installDom(true);
  const calls: string[] = [];
  setChipHost(async (method) => {
    if (method === "link.inspect" || method === "pr.inspect") calls.push(method);
    return method === "pr.inspect" ? { pullRequest: null, reading: true } : {};
  });
  const polling = spyOn(globalThis, "setInterval");
  try {
    await render(
      container,
      chat([assistant("https://github.com/acme/app/pull/12 and https://github.com/acme/app/issues/9", 1)]),
    );
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(section(container, "changes")).toBeNull();
    expect(section(container, "sources")).not.toBeNull();
    expect(calls).toEqual([]);
    expect(polling.mock.calls.map(([, ms]) => ms).filter((ms) => ms === 60_000 || ms === 1_500)).toEqual([]);
  } finally {
    polling.mockRestore();
    setChipHost(undefined);
    resetPullRequestStore();
    resetChangesStatuses();
  }
});

test("a pull request named only inside a quoted --body or --title is not the one the command touched", () => {
  const made = sessionSummary(
    chat([
      activity([ran('gh pr comment 12 -R acme/a --body "dup of https://github.com/acme/b/pull/9"')], 2),
      activity([ran("gh pr edit 5 -R acme/c --title 'Follow acme/d#3'")], 1),
    ]).rows,
  );
  const urls = made.pullRequests.map((pr) => pr.url).sort();
  expect(urls).toEqual(["https://github.com/acme/a/pull/12", "https://github.com/acme/c/pull/5"]);
});

test("a pull request row shows its line counts, the failing checks already on base dimmed, and its owner", async () => {
  const container = installDom(true);
  const url = "https://github.com/acme/atlas-web/pull/12";
  const made = sessionSummary(chat([activity([opened(12, "Retry")], 1)]).rows);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfo
        made={made}
        statuses={{
          [url]: {
            additions: 120,
            deletions: 30,
            breakdown: {
              code: { additions: 100, deletions: 30 },
              tests: { additions: 20, deletions: 0 },
            },
            checks: "failing",
            failing: 3,
            failingOnBase: 2,
            owner: "session-info",
          },
        }}
      />,
    );
  });
  const row = section(container, "changes")!.querySelector<HTMLElement>("li.acpmux-session-info-pr")!;
  expect(row.querySelector(".acpmux-session-info-pr__counts")?.textContent).toBe("+120-30");
  expect(row.querySelector(".acpmux-session-info-pr__checks")?.textContent).toBe("3 failing (2 already on base)");
  expect(row.querySelector(".acpmux-session-info-pr__base")?.textContent).toBe(" (2 already on base)");
  expect(row.querySelector(".acpmux-session-info-pr__owner")?.textContent).toBe("Owner session-info");
});

test("a pull request the chat closed shows Closed until the App reads it again after the close", async () => {
  const container = installDom(true);
  const url = "https://github.com/acme/atlas-web/pull/13";
  const status = (state: string, at: number) => {
    setSystemTime(new Date(at));
    setHeaderState({
      pullRequest: {
        url,
        number: 13,
        title: "Retry",
        state,
        checks: { state: "failing", passed: 3, total: 5 },
      },
    });
  };
  // The App read it open before the chat closed it at 2000.
  status("open", 1000);
  const closedChat = chat([activity([opened(13, "Retry"), ran("gh pr close 13", 2000)], 2)]);
  try {
    await render(container, closedChat);
    const row = () => section(container, "changes")!.querySelector<HTMLElement>("li.acpmux-session-info-pr")!;
    // That older open read doesn't undo the close.
    expect(row().dataset.state).toBe("closed");
    expect(row().querySelector(".acpmux-session-info-pr__checks")).toBeNull();

    // Later reads: closed, then someone reopened it.
    status("closed", 3000);
    await render(container, closedChat);
    expect(row().dataset.state).toBe("closed");
    status("open", 4000);
    await render(container, closedChat);
    expect(row().dataset.state).toBe("open");
    expect(row().querySelector(".acpmux-session-info-pr__checks")?.textContent).toBe("Failing");

    // Hiding and showing Session Info keeps the reopen.
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

/// The Subagents lines in order: each one's name and its state.
const lines = (element: Element) =>
  [...element.querySelectorAll<HTMLButtonElement>("button.acpmux-agent-line__button")].map((line) => [
    line.querySelector(".acpmux-summary-agent__name")?.textContent,
    line.querySelector(".acpmux-summary-agent__state")?.textContent,
  ]);
const endedRow = (element: Element) =>
  element.querySelector<HTMLButtonElement>("button.acpmux-session-info-subagents__ended");

test("Subagents names each running one on its line, and folds the ended ones into one row that opens", async () => {
  const container = installDom(true);
  const agents = [
    ...[0, 1, 2].map((index) => subagent(index, "running")),
    ...Array.from({ length: 40 }, (_, index) => subagent(3 + index, index === 5 ? "failed" : "completed")),
  ];
  const shown: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo agents={agents} onOpenSubagent={(id) => shown.push(id)} />);
  });
  const subagents = section(container, "subagents")!;
  expect(meta(subagents)).toBe("3 running · 1 failed · 39 done");
  // No row of identical avatars and no "+N": the running ones by name, oldest first.
  expect(subagents.querySelector(".acpmux-session-info-subagents__running .cv-subagent-avatar")).toBeNull();
  expect(subagents.textContent).not.toMatch(/\+\d/);
  expect(lines(subagents)).toEqual([
    ["Agent 0", "Running"],
    ["Agent 1", "Running"],
    ["Agent 2", "Running"],
  ]);
  // Each running line is one step of the shared running wave.
  expect(
    [...subagents.querySelectorAll<HTMLElement>(".acpmux-wave-item")].map((icon) =>
      icon.style.getPropertyValue("--wave-index"),
    ),
  ).toEqual(["0", "1", "2"]);
  await click(subagents.querySelectorAll<HTMLButtonElement>("button.acpmux-agent-line__button")[1]!);
  expect(shown).toEqual(["agent-1"]);
  // The ended ones are one row, folded.
  const ended = endedRow(subagents)!;
  expect(ended.textContent).toBe("39 done · 1 failed");
  // The compact completed summary previews four agents without replacing their named rows.
  expect(ended.querySelectorAll(".cv-subagent-avatar")).toHaveLength(4);
  expect(ended.querySelector('[aria-hidden="true"]')?.querySelectorAll(".cv-subagent-avatar")).toHaveLength(4);
  expect(ended.querySelector(".acpmux-wave-item")).toBeNull();
  expect(ended.getAttribute("aria-expanded")).toBe("false");
  expect(lines(subagents)).toHaveLength(3);
  await click(ended);
  expect(ended.getAttribute("aria-expanded")).toBe("true");
  const list = subagents.querySelector(".acpmux-session-info-subagents__list")!;
  // The failed one first, then the done ones, newest first; each opens its subagent.
  expect(lines(list).slice(0, 3)).toEqual([
    ["Agent 8", "Failed"],
    ["Agent 42", "Done"],
    ["Agent 41", "Done"],
  ]);
  expect(lines(list)).toHaveLength(40);
  await click(list.querySelector<HTMLButtonElement>("button.acpmux-agent-line__button")!);
  expect(shown).toEqual(["agent-1", "agent-8"]);
  await click(ended);
  expect(subagents.querySelector(".acpmux-session-info-subagents__list")).toBeNull();
});

test("200 streamed tokens do not render the completed avatar preview again", async () => {
  const container = installDom(true);
  const avatarRenders = spyOn(subagentGroup, "Avatar");
  const toneHashes = spyOn(tones, "agentTone");
  const completed = Array.from({ length: 31 }, (_, index) => subagent(index, "completed"));
  const paint = async (tokens: number, agents = completed) => {
    await act(async () => {
      root ??= createRoot(container);
      root.render(
        <>
          <p>{"token ".repeat(tokens)}</p>
          {/* Streaming rows/views rebuild the folded agents: new array and objects each update. */}
          <SessionInfo agents={agents.map((agent) => ({ ...agent, tokens }))} />
        </>,
      );
    });
  };
  try {
    await paint(0);
    expect(avatarRenders).toHaveBeenCalledTimes(4);
    const initialHashes = toneHashes.mock.calls.length;
    for (let token = 1; token <= 200; token++) await paint(token);
    expect(container.querySelector("p")?.textContent?.trim().split(" ")).toHaveLength(200);
    expect(avatarRenders).toHaveBeenCalledTimes(4);
    expect(toneHashes).toHaveBeenCalledTimes(initialHashes);
    expect(endedRow(container)?.textContent).toBe("31 done");

    // A new ended agent changes the preview; real changes must not be frozen by memoization.
    await paint(201, [...completed, subagent(31, "completed")]);
    expect(avatarRenders).toHaveBeenCalledTimes(8);
    expect(endedRow(container)?.textContent).toBe("32 done");
    // The same identity can receive corrected state/harness metadata after its first snapshot.
    await paint(202, [...completed, { ...subagent(31, "failed"), harness: "codex" }]);
    expect(avatarRenders).toHaveBeenCalledTimes(12);
    expect(endedRow(container)?.querySelector(".cv-subagent-avatar")?.getAttribute("data-state")).toBe("failed");
  } finally {
    avatarRenders.mockRestore();
    toneHashes.mockRestore();
  }
});

test("a nested subagent waiting on the person stays under the one that spawned it", async () => {
  const container = installDom(true);
  const agents = [subagent(0, "running"), subagent(1, "running"), { ...subagent(2, "running"), parent: "agent-1" }];
  await act(async () => {
    root = createRoot(container);
    // Agent 2 asks the person for a permission.
    root.render(<SessionInfo agents={agents} waiting={new Set(["agent-2"])} onOpenSubagent={noop} />);
  });
  const subagents = section(container, "subagents")!;
  expect(lines(subagents)).toEqual([
    ["Agent 0", "Running"],
    ["Agent 1", "Running"],
    ["Agent 2", "Waiting"],
  ]);
});

test("past five running lines, Show more opens the rest and Show less folds them back", async () => {
  const container = installDom(true);
  const agents = Array.from({ length: 8 }, (_, index) => subagent(index, "running"));
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo agents={agents} onOpenSubagent={noop} />);
  });
  const subagents = section(container, "subagents")!;
  expect(lines(subagents)).toHaveLength(5);
  expect(endedRow(subagents)).toBeNull();
  const more = subagents.querySelector<HTMLButtonElement>("button.acpmux-session-info-subagents__more")!;
  expect(more.textContent).toBe("Show 3 more");
  await click(more);
  expect(lines(subagents)).toHaveLength(8);
  expect(more.textContent).toBe("Show less");
  await click(more);
  expect(lines(subagents)).toHaveLength(5);
});

const started = (
  sessionId: string,
  title: string,
  state: StartedSession["state"],
  createdAt: number,
): StartedSession => ({
  sessionId,
  title,
  state,
  createdAt,
});

test("the chats the agent started are listed under Subagents, counted with them, and a row opens its chat", async () => {
  const container = installDom(true);
  const sessions = [
    started("c1", "Draft the release notes", "idle", 1),
    started("c2", "Migrate the settings store", "running", 2),
    started("c3", "Rename the settings keys", "waiting", 3),
    started("c4", "Fix the flaky drag test", "failed", 4),
    started("c5", "Port the history page", "running", 5),
  ];
  const opened: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SessionInfo
        agents={[subagent(0, "running"), subagent(1, "completed")]}
        sessions={sessions}
        onOpenSession={(id) => opened.push(id)}
      />,
    );
  });
  const subagents = section(container, "subagents")!;
  expect(meta(subagents)).toBe("1 waiting · 3 running · 1 failed · 2 done");
  // Running: the chat waiting on the person first, then the subagent and the running chats.
  expect(lines(subagents)).toEqual([
    ["Rename the settings keys", "Waiting"],
    ["Agent 0", "Running"],
    ["Port the history page", "Running"],
    ["Migrate the settings store", "Running"],
  ]);
  await click(subagents.querySelectorAll<HTMLButtonElement>("button.acpmux-agent-line__button")[2]!);
  expect(opened).toEqual(["c5"]);
  // Ended: one row, which opens into the failed chat, then the done ones.
  expect(endedRow(subagents)!.textContent).toBe("2 done · 1 failed");
  await click(endedRow(subagents)!);
  const list = subagents.querySelector(".acpmux-session-info-subagents__list")!;
  expect(lines(list)).toEqual([
    ["Fix the flaky drag test", "Failed"],
    ["Agent 1", "Done"],
    ["Draft the release notes", "Done"],
  ]);
  await click(list.querySelector<HTMLButtonElement>("button.acpmux-agent-line__button")!);
  expect(opened).toEqual(["c5", "c4"]);
});

test("with only started chats Subagents is still drawn, and the running line's count lands on it", async () => {
  const container = installDom(true);
  const opened: string[] = [];
  const sessions = {
    list: [
      started("c1", "Migrate the settings store", "running", 1),
      started("c2", "Port the history page", "idle", 2),
    ],
    onOpen: (id: string) => opened.push(id),
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane snapshot={localChat} onOpenOutput={noop} sessions={sessions} />);
  });
  // What it made (Outputs) comes before what it runs (Subagents): SessionInfo.tsx RAIL_LAYOUT.
  expect(sectionIds(container)).toEqual(["environment", "context", "outputs", "subagents"]);
  expect(meta(section(container, "subagents"))).toBe("1 running · 1 done");
  // Closed, with Subagents folded: the running line's "2 subagents" opens it at Subagents.
  await click(head(section(container, "subagents")!));
  await click(toggle(container)!);
  expect(panel(container)).toBeNull();
  await act(async () => reveal!("subagents"));
  expect(panel(container)).not.toBeNull();
  const subagents = section(container, "subagents")!;
  expect(sessionInfoState().sections.subagents).toBe(true);
  expect(lines(subagents)).toEqual([["Migrate the settings store", "Running"]]);
  expect(endedRow(subagents)!.textContent).toBe("1 done");
  await click(subagents.querySelector<HTMLButtonElement>("button.acpmux-agent-line__button")!);
  expect(opened).toEqual(["c1"]);
});

test("a Cloud VM chat's children, as its machine's daemon lists them with the chat, show under Subagents", async () => {
  const container = installDom(true);
  // `_acpmux/watch` for a chat on another machine (RemoteAcpmuxWire): the chat's own summary, then
  // the chats it started there (`agent-session-children-v1`): a sub-session, named by `startedBy`
  // and, while its parent is listed, `spawnedBy`, and an `acpmux new` chat named by `spawnedBy`.
  // A grandchild (acpmux keeps `spawnedBy` one level) lists under its own parent, not this chat.
  const watch = {
    sessions: [
      {
        sessionId: "vm-root",
        title: "Ship the uploader",
        status: "running",
        host: "build-01",
        hostKind: "cloud",
      },
      {
        sessionId: "vm-sub",
        title: "Run the e2e suite",
        status: "running",
        host: "build-01",
        hostKind: "cloud",
        startedBy: "vm-root",
        spawnedBy: "vm-root",
        createdAt: 2,
      },
      {
        sessionId: "vm-new",
        title: "Draft the release notes",
        status: "idle",
        host: "build-01",
        hostKind: "cloud",
        spawnedBy: "vm-root",
        createdAt: 1,
      },
      {
        sessionId: "vm-grandchild",
        title: "Check one shard",
        status: "running",
        host: "build-01",
        hostKind: "cloud",
        startedBy: "vm-sub",
        spawnedBy: null,
        createdAt: 3,
      },
    ],
  };
  // The App's path (App.tsx `childSessions`).
  const entries = watch.sessions.map((session) => sessionEntry(session));
  const children = startedSessions(spawnedSessions(entries, "vm-root"), "vm-root");
  const opened: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<SessionInfo sessions={children} onOpenSession={(id) => opened.push(id)} />);
  });
  const subagents = section(container, "subagents")!;
  expect(meta(subagents)).toBe("1 running · 1 done");
  await click(endedRow(subagents)!);
  expect(lines(subagents)).toEqual([
    ["Run the e2e suite", "Running"],
    ["Draft the release notes", "Done"],
  ]);
  await click(subagents.querySelector<HTMLButtonElement>("button.acpmux-agent-line__button")!);
  expect(opened).toEqual(["vm-sub"]);
});
