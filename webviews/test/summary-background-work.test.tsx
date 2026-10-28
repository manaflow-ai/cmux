// l10n-allow-file: test fixture commands and chat titles, not shipped UI.
// Background work is visible (Leo: "where is the background showing?"). With the Inspector off
// (Debug Settings `agent.inspector`), the summary card lists the chat's background commands live
// (inspector/processes.ts `backgroundCommands`, whose merge chat-inspector-tasks.test.tsx covers),
// running ones first with their time and Stop, and finished work as compact status cards; the chats
// the agent started sit under Subagents with their state; an empty card draws one quiet line instead
// of "None" under every title. The running turn's line counts started chats. What still runs
// between turns shows in the tray above the composer (subagent-tray.test.tsx).
import { afterEach, expect, jest, setSystemTime, test } from "bun:test";
import { act, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import {
  type WorkingCounts,
  WorkingCountsContext,
  WorkingFor,
} from "../src/agent-session/acpmux/conversation/WorkingFor";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { StartedSession } from "../src/agent-session/acpmux/started/startedSessions";
import { orderedSessions } from "../src/agent-session/acpmux/inspector/ChildSessionRows";
import { backgroundCommands, processesOf } from "../src/agent-session/acpmux/inspector/processes";
import type { SessionSummary, SummaryBackgroundTask } from "../src/agent-session/acpmux/summary/sessionSummary";
import { SubagentStatusList } from "../src/agent-session/acpmux/summary/SubagentStatusList";
import { SummaryBody } from "../src/agent-session/acpmux/summary/SummaryBody";
import { WorkflowSummaryRow } from "../src/agent-session/acpmux/summary/WorkflowSummary";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  jest.useRealTimers();
  setSystemTime();
});

async function render(container: HTMLElement, element: ReactElement) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(element);
  });
}

/// A record as acpmux sends it (hub/processes.rs `Process`).
const wire = (task: string, command: string, state: string, startedAt: number, endedAt?: number) => ({
  id: `s1/${task}`,
  sessionId: "s1",
  toolCallId: `call-${task}`,
  taskId: task,
  harness: "claude",
  command,
  startedAt,
  endedAt: endedAt ?? null,
  state,
  origin: "background",
});

const task = (id: string, command: string, state: SummaryBackgroundTask["state"], startedAt?: number) =>
  ({ id, command, state, ...(startedAt !== undefined ? { startedAt } : {}) }) satisfies SummaryBackgroundTask;

const emptySummary = (fields: Partial<SessionSummary> = {}): SessionSummary => ({
  scheduled: [],
  pullRequests: [],
  outputs: [],
  subagents: [],
  sources: [],
  backgroundTasks: [],
  ...fields,
});

test("the card keeps mixed running, completed and failed task cards visible", async () => {
  // The running times tick on a clock the test moves.
  jest.useFakeTimers();
  setSystemTime(new Date(100_000));
  const container = installDom();
  const commands = backgroundCommands(
    processesOf(
      {
        processes: [
          wire("a", "bun run dev", "running", 100_000 - 76_000),
          wire("b", "cargo test", "exited", 1_000, 9_000),
          wire("c", "tsc --watch", "running", 100_000 - 3_723_000),
        ],
      },
      "s1",
    ),
    [task("call-d", "npm run lint", "failed", 500)],
    true,
  );
  const stopped: string[] = [];
  await render(
    container,
    <SummaryBody summary={emptySummary()} commands={commands} onStopCommand={async (id) => void stopped.push(id)} />,
  );
  const section = container.querySelector<HTMLElement>('section[aria-label="Background tasks"]')!;
  const rows = () =>
    [...section.querySelectorAll<HTMLElement>(".acpmux-summary-task")].map((row) => [
      row.querySelector(".acpmux-summary-text")?.textContent,
      row.querySelector(".acpmux-summary-meta")?.textContent,
    ]);
  expect(rows()).toEqual([
    ["bun run dev", "1m 16s"],
    ["tsc --watch", "1h 2m 3s"],
    ["cargo test", "Finished"],
    ["npm run lint", "Failed"],
  ]);
  expect([...section.querySelectorAll<HTMLElement>(".acpmux-summary-task")].map((row) => row.dataset.state)).toEqual([
    "running",
    "running",
    "completed",
    "failed",
  ]);
  // Stop only on running rows the registry lists.
  const stops = [...section.querySelectorAll<HTMLButtonElement>("button.acpmux-chat-inspector-stop")];
  expect(stops.map((stop) => stop.getAttribute("aria-label"))).toEqual(["Stop bun run dev", "Stop tsc --watch"]);
  await act(async () => stops[0]!.click());
  expect(stopped).toEqual(["s1/a"]);
  // The time ticks: two seconds on, the row reads two seconds more.
  await act(async () => void jest.advanceTimersByTime(2_000));
  expect(rows()[0]).toEqual(["bun run dev", "1m 18s"]);
});

test("a running card keeps its key and detail when the process completes", async () => {
  const container = installDom();
  const running = {
    id: "call-a",
    command: "bun test",
    description: "Run the focused tests",
    state: "running" as const,
    startedAt: 1_000,
    toolCallId: "call-a",
  };
  await render(container, <SummaryBody summary={emptySummary()} commands={[running]} />);
  const before = container.querySelector<HTMLElement>(".acpmux-summary-task")!;
  expect(before.dataset.state).toBe("running");
  expect(before.querySelector(".acpmux-summary-task__description")?.textContent).toBe("Run the focused tests");
  expect(before.querySelector(".acpmux-summary-task__command")?.textContent).toBe("bun test");
  const completed = { ...running, state: "completed" as const, endedAt: 3_000 };
  await render(container, <SummaryBody summary={emptySummary()} commands={[completed]} />);
  const after = container.querySelector<HTMLElement>(".acpmux-summary-task")!;
  expect(after).toBe(before);
  expect(after.dataset.state).toBe("completed");
  expect(after.querySelector(".acpmux-summary-meta")?.textContent).toBe("Finished");
});

test("a card with nothing draws no empty sections, one quiet line and Attach files or folders", async () => {
  const container = installDom();
  let attached = 0;
  await render(container, <SummaryBody summary={emptySummary()} onAttach={() => (attached += 1)} />);
  expect(container.querySelectorAll("section")).toHaveLength(0);
  expect(container.textContent).not.toContain("None");
  expect(container.querySelector(".acpmux-summary-empty")?.textContent).toBe(
    "Nothing yet: outputs, subagents, sources and background tasks show here",
  );
  const attach = container.querySelector<HTMLButtonElement>(".acpmux-summary-attach")!;
  expect(attach.textContent).toBe("Attach files or folders");
  await act(async () => attach.click());
  expect(attached).toBe(1);
});

test("a section with something draws alone; Sources keeps its + and the quiet line goes", async () => {
  const container = installDom();
  await render(
    container,
    <SummaryBody
      summary={emptySummary({ sources: [{ url: "https://example.com/a", label: "example.com/a" }] })}
      onAttach={() => undefined}
    />,
  );
  expect([...container.querySelectorAll("section")].map((section) => section.getAttribute("aria-label"))).toEqual([
    "Sources",
  ]);
  expect(container.querySelector('section[aria-label="Sources"] .acpmux-summary-add')).not.toBeNull();
  expect(container.querySelector(".acpmux-summary-attach")).toBeNull();
  expect(container.querySelector(".acpmux-summary-empty")).toBeNull();
});

const child = (
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

test("the chats the agent started are listed under Subagents with their state, and a row opens its chat", async () => {
  const container = installDom();
  const sessions = [
    child("c1", "Draft the release notes", "idle", 1),
    child("c2", "Migrate the settings store", "running", 2),
    child("c3", "Rename the settings keys", "waiting", 3),
    child("c4", "Fix the flaky drag test", "failed", 4),
    child("c5", "Port the history page", "running", 5),
  ];
  expect(orderedSessions(sessions).map((session) => session.sessionId)).toEqual(["c3", "c5", "c2", "c4", "c1"]);
  const opened: string[] = [];
  await render(
    container,
    <SubagentStatusList agents={[]} waiting={new Set()} sessions={sessions} onOpenSession={(id) => opened.push(id)} />,
  );
  const section = container.querySelector<HTMLElement>('section[aria-label="Subagents"]')!;
  // Running started chats count in the title, as running subagents do.
  expect(section.querySelector("h3")?.textContent).toBe("Subagents · 2 running");
  const rows = [...section.querySelectorAll<HTMLButtonElement>(".acpmux-summary-session")];
  expect(
    rows.map((row) => [
      row.querySelector(".acpmux-summary-agent__name")?.textContent,
      row.querySelector(".acpmux-summary-agent__state")?.textContent,
      row.querySelector(".acpmux-lineage__icon")?.getAttribute("data-state"),
    ]),
  ).toEqual([
    ["Rename the settings keys", "Waiting", "waiting"],
    ["Port the history page", "Running", "running"],
    ["Migrate the settings store", "Running", "running"],
    ["Fix the flaky drag test", "Failed", "failed"],
    ["Draft the release notes", "Done", "done"],
  ]);
  expect(section.textContent).not.toContain("None");
  await act(async () => rows[1]!.click());
  expect(opened).toEqual(["c5"]);
});

const counts = (extra: Partial<WorkingCounts> = {}): WorkingCounts => ({
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  ...extra,
});
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("unavailable workflow resume refuses visibly and leaves Run again available", async () => {
  const container = installDom();
  const requests: boolean[] = [];
  await render(
    container,
    <WorkflowSummaryRow
      workflow={{ id: "node", title: "Review", state: "paused", phases: [], agents: [] }}
      actions={{
        onDraftWorkflow: (resume) => {
          requests.push(resume);
          return !resume;
        },
      }}
    />,
  );
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-workflow__row")!.click());
  const button = (label: string) =>
    [...container.querySelectorAll<HTMLButtonElement>("button")].find((entry) => entry.textContent === label)!;
  await act(async () => button("Resume").click());
  expect(container.textContent).toContain("This workflow can’t be resumed");
  await act(async () => button("Run again").click());
  expect(requests).toEqual([true, false]);
});

test("the running turn's line counts the started chats that run", () => {
  const status: AcpmuxRow = { id: "working", kind: "working", version: 1, at: 0 };
  const html = renderToStaticMarkup(
    <WorkingCountsContext.Provider value={counts({ commands: 2, sessions: 3 })}>
      <WorkingFor row={status} now={() => 26_000} />
    </WorkingCountsContext.Provider>,
  );
  expect(text(html)).toBe("Working for 26s · 3 subagents · 2 commands");
});
