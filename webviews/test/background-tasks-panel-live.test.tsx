// l10n-allow-file: test fixture names, not shipped UI.
// The Background tasks panel (backgroundTasks/BackgroundTasksPanel.tsx): a group whose own agent
// ended still runs while a nested agent of it does (spinner, live time, open at first), and a
// transcript opened before acpmux streamed any of its rows mounts one window of the rows that
// arrive, not every row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { backgroundGroups, type BackgroundGroup } from "../src/agent-session/acpmux/backgroundTasks/backgroundTasks";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { BackgroundTasksPanel } from "../src/agent-session/acpmux/backgroundTasks/BackgroundTasksPanel";
import {
  NestedAgents,
  SubagentTranscript,
  WINDOW,
} from "../src/agent-session/acpmux/backgroundTasks/SubagentTranscript";

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
    CSS: { escape: (value: string) => value },
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
});

const rows = (n: number): AcpmuxRow[] =>
  Array.from({ length: n }, (_, index) => ({ id: `r${index}`, version: 1, at: index, kind: "assistant", text: "x" }));

test("a group whose agent ended runs while its nested agent does", async () => {
  const container = installDom();
  const group: BackgroundGroup = {
    id: "agent:a",
    kind: "agent",
    name: "Parent agent",
    state: "done",
    startedAt: 1_000,
    endedAt: 2_000,
    running: [{ id: "b", kind: "agent", title: "Nested agent", state: "running", startedAt: 1_500, agentId: "b" }],
    finished: [],
    total: 1,
    failed: 0,
    agentId: "a",
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <BackgroundTasksPanel groups={[group]} onClearFinished={() => {}} onExpand={() => {}} onClose={() => {}} />,
    ),
  );
  const block = container.querySelector<HTMLElement>('[data-group="agent:a"]')!;
  expect(block.dataset.state).toBe("running");
  expect(block.querySelector(".acpmux-bg__name .cv-spinner")).not.toBeNull();
  expect(block.textContent).toContain("Nested agent");
});

test("a transcript opened before its rows arrive mounts one window of them", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<SubagentTranscript rows={[]} running />));
  await act(async () => root!.render(<SubagentTranscript rows={rows(500)} running />));
  expect(container.querySelectorAll("[data-row-id]").length).toBe(WINDOW);
});

test("a transcript that follows its newest row keeps its mounted rows bounded as rows stream in", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<SubagentTranscript rows={rows(60)} running />));
  await act(async () => root!.render(<SubagentTranscript rows={rows(400)} running />));
  expect(container.querySelectorAll("[data-row-id]").length).toBeLessThanOrEqual(2 * WINDOW);
});

test("a finished command with no known end shows no time that keeps counting", async () => {
  const container = installDom();
  const group: BackgroundGroup = {
    id: "commands",
    kind: "commands",
    name: "This chat",
    state: "done",
    startedAt: 1_000,
    running: [],
    finished: [{ id: "c", kind: "command", title: "bun test", state: "done", startedAt: 1_000 }],
    total: 1,
    failed: 0,
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <BackgroundTasksPanel
        groups={[group]}
        look="flat"
        onClearFinished={() => {}}
        onExpand={() => {}}
        onClose={() => {}}
      />,
    ),
  );
  const times = [...container.querySelectorAll(".acpmux-bg__time")].map((node) => node.textContent ?? "");
  expect(times.length).toBeGreaterThan(0);
  expect(times.every((text) => text === "")).toBe(true);
});

test("a workflow agent opened from the panel draws its transcript, loading first, never a blank pane", async () => {
  const container = installDom();
  const workflow = {
    id: "wf-node",
    parent: null,
    name: "Workflow",
    kind: "workflow",
    state: "running",
    startedAt: 1_000,
    runId: "wf_demo",
    workflowAgents: new Map([
      [1, { index: 1, label: "review", agentId: "review", state: "running", startedAt: 1_100 }],
    ]),
  };
  const groups = backgroundGroups({
    rows: [{ id: "s", version: 1, at: 0, kind: SUBAGENTS, subagents: [workflow as never] }],
    commands: [],
    sessions: [],
    chatName: "This chat",
    sessionId: "chat",
  });
  let resolve!: (value: unknown) => void;
  const reads: unknown[] = [];
  const read = (request: unknown) => {
    reads.push(request);
    return new Promise<unknown>((done) => (resolve = done));
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <BackgroundTasksPanel
        groups={groups}
        look="flat"
        workflow={{ sessionId: "chat", chat: "This chat", connection: "connected", read }}
        onClearFinished={() => {}}
        onExpand={() => {}}
        onClose={() => {}}
      />,
    ),
  );
  const task = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-bg__task-open")].find((button) =>
    button.textContent?.includes("review"),
  );
  expect(task).toBeDefined();
  expect(task!.disabled).toBe(false);
  await act(async () => task!.click());
  const transcript = container.querySelector(".acpmux-bg__transcript")!;
  expect(transcript).not.toBeNull();
  // The click's own frame shows the loading state, not an empty pane.
  expect(transcript.textContent).toContain("Loading");
  expect(reads).toEqual([{ sessionId: "chat", runId: "wf_demo", agentId: "review" }]);
  await act(async () =>
    resolve({
      start: 0,
      end: 1,
      lines: 1,
      truncated: false,
      updates: [{ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Reviewed the diff" } }],
    }),
  );
  expect(transcript.textContent).toContain("Reviewed the diff");
  expect(transcript.textContent).not.toContain("Loading");
});

test("a workflow named in a subagent's transcript opens no empty transcript", async () => {
  const container = installDom();
  const opened: string[] = [];
  const workflowRow: AcpmuxRow = {
    id: "w",
    version: 1,
    at: 0,
    kind: SUBAGENTS,
    subagents: [{ id: "wf", parent: "a", name: "Workflow", kind: "workflow", state: "running", startedAt: 1 }],
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <NestedAgents.Provider value={{ open: (id) => opened.push(id) }}>
        <SubagentTranscript rows={[workflowRow]} running />
      </NestedAgents.Provider>,
    ),
  );
  const line = container.querySelector<HTMLButtonElement>(".acpmux-bg__task-open")!;
  expect(line.disabled).toBe(true);
  await act(async () => line.click());
  expect(opened).toEqual([]);
});

test("a workflow agent's transcript loads its older history when the reader scrolls to the top", async () => {
  const container = installDom();
  const observers: { fire(): void }[] = [];
  scope.IntersectionObserver = class {
    constructor(private readonly callback: (entries: { isIntersecting: boolean }[]) => void) {}
    observe() {
      observers.push({ fire: () => this.callback([{ isIntersecting: true }]) });
    }
    disconnect() {}
  };
  saved.set("IntersectionObserver", undefined);
  const workflow = {
    id: "wf-node",
    parent: null,
    name: "Workflow",
    kind: "workflow",
    state: "running",
    startedAt: 1_000,
    runId: "wf_demo",
    workflowAgents: new Map([
      [1, { index: 1, label: "review", agentId: "review", state: "running", startedAt: 1_100 }],
    ]),
  };
  const groups = backgroundGroups({
    rows: [{ id: "s", version: 1, at: 0, kind: SUBAGENTS, subagents: [workflow as never] }],
    commands: [],
    sessions: [],
    chatName: "This chat",
    sessionId: "chat",
  });
  const text = (value: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: value } });
  const reads: Record<string, unknown>[] = [];
  const read = async (request: Record<string, unknown>) => {
    reads.push(request);
    return request.before === undefined
      ? { start: 200, end: 400, lines: 400, truncated: false, updates: [text("The newest page")] }
      : { start: 0, end: 200, lines: 400, truncated: false, updates: [text("The oldest page")] };
  };
  const pane = 'workflow:["chat","wf_demo","review"]';
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <BackgroundTasksPanel
        groups={groups}
        initialDrill={{ agentId: pane, workflow: true }}
        workflow={{ sessionId: "chat", chat: "This chat", connection: "connected", read: read as never }}
        onClearFinished={() => {}}
        onExpand={() => {}}
        onClose={() => {}}
      />,
    ),
  );
  const transcript = container.querySelector(".acpmux-bg__transcript")!;
  expect(transcript.textContent).toContain("The newest page");
  expect(observers.length).toBeGreaterThan(0);
  await act(async () => observers.at(-1)!.fire());
  expect(reads.at(-1)).toMatchObject({ before: 200 });
  expect(transcript.textContent).toContain("The oldest page");
});

test("a transcript replaced by fewer rows shows all of them, not only the last", async () => {
  const container = installDom();
  const fresh = (n: number): AcpmuxRow[] =>
    Array.from({ length: n }, (_, index) => ({ id: `n${index}`, version: 2, at: index, kind: "assistant", text: "y" }));
  root = createRoot(container);
  await act(async () => root!.render(<SubagentTranscript rows={rows(500)} running />));
  await act(async () => root!.render(<SubagentTranscript rows={fresh(30)} running />));
  expect(container.querySelectorAll("[data-row-id]").length).toBe(30);
});

test("older workflow text merged into the first row keeps what the reader sees in place", async () => {
  const container = installDom();
  const observers: { fire(): void }[] = [];
  scope.IntersectionObserver = class {
    constructor(private readonly callback: (entries: { isIntersecting: boolean }[]) => void) {}
    observe() {
      observers.push({ fire: () => this.callback([{ isIntersecting: true }]) });
    }
    disconnect() {}
  };
  saved.set("IntersectionObserver", undefined);
  let loaded = false;
  const row = (): AcpmuxRow => ({
    id: "r0",
    version: loaded ? 2 : 1,
    at: 0,
    kind: "assistant",
    text: loaded ? "Older text read from the page before. The newest text." : "The newest text.",
  });
  let rerender: () => Promise<void> = async () => {};
  const loadOlder = async () => {
    loaded = true;
    await rerender();
  };
  root = createRoot(container);
  rerender = () =>
    act(async () => root!.render(<SubagentTranscript rows={[row()]} running={false} onLoadOlder={loadOlder} />));
  await rerender();
  const view = container.querySelector<HTMLElement>(".acpmux-bg__transcript")!;
  // One pixel per character of text; scrollTop as a plain value (JSDOM lays nothing out).
  Object.defineProperty(view, "scrollHeight", { get: () => (view.textContent ?? "").length * 10 });
  Object.defineProperty(view, "clientHeight", { value: 40 });
  let top = 0;
  Object.defineProperty(view, "scrollTop", { get: () => top, set: (value: number) => (top = value) });
  top = 20;
  view.dispatchEvent(new window.Event("scroll"));
  const fromBottom = view.scrollHeight - top;
  // The row count stays one: the older text merged into the row the reader was reading.
  await act(async () => observers.at(-1)!.fire());
  await act(async () => {});
  expect(container.querySelectorAll("[data-row-id]").length).toBe(1);
  expect(view.scrollHeight - top).toBe(fromBottom);
});

test("a paused workflow named in a transcript shows no spinner and no stop", async () => {
  const container = installDom();
  const row: AcpmuxRow = {
    id: "w",
    version: 1,
    at: 0,
    kind: SUBAGENTS,
    subagents: [
      { id: "wf", parent: "a", name: "Workflow", kind: "workflow", state: "running", paused: true, startedAt: 1 },
    ],
  };
  const nested = { open: () => {}, stop: () => <button type="button" className="probe-stop" aria-label="Stop" /> };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <NestedAgents.Provider value={nested}>
        <SubagentTranscript rows={[row]} running={false} />
      </NestedAgents.Provider>,
    ),
  );
  expect(container.querySelector(".cv-spinner")).toBeNull();
  expect(container.querySelector(".probe-stop")).toBeNull();
});

test("turning workflows off while a workflow agent's transcript shows steps back to the list", async () => {
  const container = installDom();
  const props = { groups: [], onClearFinished() {}, onExpand() {}, onClose() {} };
  const pane = 'workflow:["chat","wf_demo","review"]';
  const reads = {
    sessionId: "chat",
    chat: "This chat",
    connection: "connected",
    read: () => new Promise<never>(() => {}),
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(<BackgroundTasksPanel {...props} initialDrill={{ agentId: pane, workflow: true }} workflow={reads} />),
  );
  expect(container.querySelector(".acpmux-bg__transcript")).not.toBeNull();
  await act(async () =>
    root!.render(<BackgroundTasksPanel {...props} initialDrill={{ agentId: pane, workflow: true }} />),
  );
  expect(container.querySelector<HTMLElement>(".acpmux-bg__list")!.hidden).toBe(false);
});
