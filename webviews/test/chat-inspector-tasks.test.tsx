// l10n-allow-file: test fixture commands, not shipped UI.
// The Inspector's Background tasks (Claude Code desktop's): the chat's background
// processes from acpmux's registry (`_acpmux/process/list` and `process_update`), with the
// background commands only the transcript knows (Claude's background Bash, Ctrl-B's included).
// Dev servers come first with the ports their commands name; then the rest,
// running ones with their elapsed time and, for the registry's, a Stop button, then "N finished",
// folded. A row opens the command's terminal beside the chat (`chat.processTerminal`).
import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { resetInspectorState } from "../src/agent-session/acpmux/inspector/inspectorState";
import {
  backgroundCommands,
  mergeProcess,
  processesOf,
  splitCommands,
  serverOf,
  splitServers,
  useInspectorProcesses,
  type InspectorProcess,
  type ProcessSource,
} from "../src/agent-session/acpmux/inspector/processes";
import type { SummaryBackgroundTask } from "../src/agent-session/acpmux/summary/sessionSummary";

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

beforeEach(() => resetInspectorState());

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
  setSystemTime();
});

/// A record as acpmux sends it (hub/processes.rs `Process`).
const wire = (task: string, command: string, state: string, startedAt: number, endedAt?: number) => ({
  id: `s1/${task}`,
  sessionId: "s1",
  toolCallId: `call-${task}`,
  taskId: task,
  harness: "codex",
  command,
  cwd: "/Users/you/src/atlas-web",
  startedAt,
  endedAt: endedAt ?? null,
  state,
  origin: "background",
  outputBytes: null,
});

async function render(
  container: HTMLElement,
  processes: readonly InspectorProcess[],
  onStop?: (id: string) => Promise<unknown>,
  onOpenUrl?: (url: string) => void,
) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<ChatInspector processes={processes} onStopProcess={onStop} onOpenUrl={onOpenUrl} />);
  });
}

const section = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLElement>(`section.acpmux-chat-inspector-section[data-section="${id}"]`);
const meta = (element: HTMLElement | null) =>
  element?.querySelector(".acpmux-chat-inspector-section__meta")?.textContent;
const click = (element: HTMLElement) => act(async () => element.click());

const process = (command: string, state = "running"): InspectorProcess => ({
  id: command,
  command,
  startedAt: 1,
  state,
});

test("the registry's records become the session's processes, an update replacing its record", () => {
  const listed = processesOf(
    { processes: [wire("a", "bun run dev", "running", 1_000), wire("b", "cargo test", "exited", 2_000, 9_000)] },
    "s1",
  );
  expect(listed.map((record) => [record.id, record.command, record.state])).toEqual([
    ["s1/a", "bun run dev", "running"],
    ["s1/b", "cargo test", "exited"],
  ]);
  // Another chat's record and a malformed one are dropped.
  expect(processesOf({ processes: [{ ...wire("c", "x", "running", 1), sessionId: "s2" }, { id: 3 }] }, "s1")).toEqual(
    [],
  );
  const stopped = mergeProcess(listed, wire("a", "bun run dev", "killed", 1_000, 5_000), "s1");
  expect(stopped.map((record) => record.state)).toEqual(["killed", "exited"]);
  const added = mergeProcess(stopped, wire("d", "vite", "running", 6_000), "s1");
  expect(added.map((record) => record.id)).toEqual(["s1/a", "s1/b", "s1/d"]);
  expect(mergeProcess(added, { ...wire("e", "y", "running", 1), sessionId: "s2" }, "s1")).toBe(added);
});

test("a server is a command that serves, with only the ports it names", () => {
  expect(serverOf(process("bun run dev --port 5173"))?.ports).toEqual([5173]);
  expect(serverOf(process("PORT=3001 npm start"))?.ports).toEqual([3001]);
  expect(serverOf(process("python3 -m http.server 8000"))?.ports).toEqual([8000]);
  expect(serverOf(process("rails s -p 4000"))?.ports).toEqual([4000]);
  // A server whose command names no port: no guessed default.
  expect(serverOf(process("pnpm dev"))?.ports).toEqual([]);
  // Not servers: a build, a test watcher, a one-off with -p.
  expect(serverOf(process("vite build"))).toBeUndefined();
  expect(serverOf(process("bun test --watch"))).toBeUndefined();
  expect(serverOf(process("mkdir -p 8080"))).toBeUndefined();
  // A server that ended is a finished task, not a server.
  const { servers, tasks } = splitServers([process("bun run dev"), process("vite", "exited"), process("cargo test")]);
  expect(servers.map((server) => server.command)).toEqual(["bun run dev"]);
  expect(tasks.map((task) => task.command)).toEqual(["vite", "cargo test"]);
});

test("no section before the first background process; then running ones with elapsed time and Stop, and N finished folded", async () => {
  setSystemTime(new Date(100_000));
  const container = installDom();
  await render(container, []);
  expect(section(container, "tasks")).toBeNull();

  const processes = processesOf(
    {
      processes: [
        wire("a", "cargo watch -x check", "running", 100_000 - 76_000),
        wire("b", "cargo test", "exited", 1_000, 9_000),
        wire("c", "tsc --watch", "running", 100_000 - 3_723_000),
        wire("d", "npm run lint", "failed", 1_000, 2_000),
      ],
    },
    "s1",
  );
  const stopped: string[] = [];
  await render(container, processes, async (id) => void stopped.push(id));
  const tasks = section(container, "tasks")!;
  const rows = () => [...tasks.querySelectorAll<HTMLElement>(".acpmux-chat-inspector-task")];
  // Running first, newest first.
  expect(rows().map((row) => row.querySelector(".acpmux-chat-inspector-task__command")?.textContent)).toEqual([
    "cargo watch -x check",
    "tsc --watch",
  ]);
  expect(rows().map((row) => row.querySelector(".acpmux-chat-inspector-task__time")?.textContent)).toEqual([
    "1m 16s",
    "1h 2m 3s",
  ]);
  expect(tasks.querySelector(".acpmux-chat-inspector-section__meta")?.textContent).toBe("2 running");

  // The finished ones fold behind their count; open, each with how long it ran and how it ended.
  const fold = tasks.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-fold")!;
  expect(fold.textContent).toBe("2 finished");
  expect(fold.getAttribute("aria-expanded")).toBe("false");
  await click(fold);
  const finished = [...tasks.querySelectorAll<HTMLElement>("[data-finished] .acpmux-chat-inspector-task")];
  expect(finished.map((row) => row.querySelector(".acpmux-chat-inspector-task__state")?.textContent)).toEqual([
    "Finished",
    "Failed",
  ]);

  const stop = rows()[0]!.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-stop")!;
  expect(stop.getAttribute("aria-label")).toBe("Stop cargo watch -x check");
  await click(stop);
  expect(stopped).toEqual(["s1/a"]);
  // It waits for the registry's update rather than dropping the row itself.
  expect(stop.disabled).toBe(true);
});

test("a dev server heads Background tasks with its port, which opens beside the chat, and Stop", async () => {
  setSystemTime(new Date(100_000));
  const container = installDom();
  const opened: string[] = [];
  const stopped: string[] = [];
  await render(
    container,
    processesOf({ processes: [wire("a", "bun run dev --port 5173", "running", 40_000)] }, "s1"),
    async (id) => void stopped.push(id),
    (url) => opened.push(url),
  );
  // One section for every background command, a dev server's included (no Servers card of its own).
  const servers = section(container, "tasks")!;
  expect(servers.querySelector(".acpmux-chat-inspector-section__meta")?.textContent).toBe("1 running");
  expect(servers.querySelectorAll(".acpmux-chat-inspector-server")).toHaveLength(1);
  expect(servers.querySelectorAll(".acpmux-chat-inspector-task")).toHaveLength(0);
  const port = servers.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-port")!;
  expect(port.textContent).toBe(":5173");
  expect(port.getAttribute("aria-label")).toBe("Open http://localhost:5173");
  await click(port);
  expect(opened).toEqual(["http://localhost:5173"]);
  await click(servers.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-stop")!);
  expect(stopped).toEqual(["s1/a"]);
});

test("a session whose processes all finished keeps the section with only its count", async () => {
  const container = installDom();
  await render(container, processesOf({ processes: [wire("b", "cargo test", "exited", 1_000, 9_000)] }, "s1"));
  const tasks = section(container, "tasks")!;
  expect(tasks.querySelectorAll(".acpmux-chat-inspector-task")).toHaveLength(0);
  expect(tasks.querySelector("button.acpmux-chat-inspector-fold")?.textContent).toBe("1 finished");
  // No Stop without a way to stop.
  expect(tasks.querySelector("button.acpmux-chat-inspector-stop")).toBeNull();
});

/// A client whose list answers when the test says, and whose updates the test sends.
function fakeSource() {
  const listeners = new Set<(process: unknown) => void>();
  const lists: { sessionId: string; answer: (reply: unknown) => void; fail: () => void }[] = [];
  const source: ProcessSource = {
    listProcesses: (sessionId) =>
      new Promise((answer, fail) => lists.push({ sessionId, answer, fail: () => fail(new Error("refused")) })),
    watchProcesses: (listener) => {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
  };
  const send = (process: unknown) => act(async () => listeners.forEach((listener) => listener(process)));
  return { source, lists, listeners, send };
}

let seen: readonly InspectorProcess[] = [];
function Probe({ source, sessionId }: { source: ProcessSource; sessionId: string }) {
  seen = useInspectorProcesses(source, sessionId, true);
  return null;
}
const mount = (container: HTMLElement, source: ProcessSource, sessionId: string) =>
  act(async () => {
    root ??= createRoot(container);
    root.render(<Probe source={source} sessionId={sessionId} />);
  });
const states = () => seen.map((process) => `${process.id}:${process.state}`);

test("an update that arrives before the list wins over the list's older record", async () => {
  const container = installDom();
  const { source, lists, send } = fakeSource();
  await mount(container, source, "s1");
  await send(wire("a", "bun run dev", "killed", 1_000, 5_000));
  await act(async () =>
    lists[0]!.answer({ processes: [wire("a", "bun run dev", "running", 1_000), wire("b", "vite", "running", 2_000)] }),
  );
  expect(states()).toEqual(["s1/a:killed", "s1/b:running"]);
  // Later updates still land.
  await send(wire("b", "vite", "exited", 2_000, 9_000));
  expect(states()).toEqual(["s1/a:killed", "s1/b:exited"]);
});

test("a refused list keeps what the updates said; another chat starts empty; a new client lists again", async () => {
  const container = installDom();
  const first = fakeSource();
  await mount(container, first.source, "s1");
  await first.send(wire("a", "bun run dev", "running", 1_000));
  await act(async () => lists(first)[0]!.fail());
  expect(states()).toEqual(["s1/a:running"]);

  // Another chat: none of s1's, and s1's listener is gone.
  await mount(container, first.source, "s2");
  expect(seen).toEqual([]);
  expect(first.listeners.size).toBe(1);
  expect(lists(first).map((list) => list.sessionId)).toEqual(["s1", "s2"]);

  // A reconnect hands over a new client: it subscribes there and lists again.
  const second = fakeSource();
  await mount(container, second.source, "s2");
  expect(first.listeners.size).toBe(0);
  expect(second.listeners.size).toBe(1);
  await act(async () =>
    lists(second)[0]!.answer({
      processes: [{ ...wire("c", "tsc --watch", "running", 3_000), id: "s2/c", sessionId: "s2" }],
    }),
  );
  expect(states()).toEqual(["s2/c:running"]);
});
const lists = (fake: ReturnType<typeof fakeSource>) => fake.lists;

test("a refused Stop says so and can be tried again", async () => {
  const container = installDom();
  let refuse = true;
  await render(container, processesOf({ processes: [wire("a", "cargo watch", "running", 1_000)] }, "s1"), async () => {
    if (refuse) throw new Error("refused");
  });
  const stop = () =>
    section(container, "tasks")!.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-stop")!;
  await act(async () => stop().click());
  expect(stop().getAttribute("data-state")).toBe("failed");
  expect(stop().getAttribute("aria-label")).toBe("Couldn’t stop cargo watch");
  expect(stop().disabled).toBe(false);
  refuse = false;
  await act(async () => stop().click());
  expect(stop().getAttribute("data-state")).toBe("stopping");
});

const task = (id: string, command: string, state: SummaryBackgroundTask["state"], startedAt?: number) =>
  ({ id, command, state, ...(startedAt !== undefined ? { startedAt } : {}) }) satisfies SummaryBackgroundTask;

/// What the page posts to the native host (CmuxNextAgentPane's `agentSession` handler).
function recordNative(): { method: string; params: Record<string, unknown> }[] {
  const posted: { method: string; params: Record<string, unknown> }[] = [];
  Object.assign(dom!.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params: Record<string, unknown> }) => {
            posted.push({ method: message.method, params: message.params });
            return { ok: true, value: { opened: true } };
          },
        },
      },
    },
  });
  return posted;
}

async function renderInspector(container: HTMLElement, props: ComponentProps<typeof ChatInspector>) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<ChatInspector {...props} />);
  });
}
const taskRows = (container: HTMLElement) =>
  [...(section(container, "tasks")?.querySelectorAll<HTMLElement>(".acpmux-chat-inspector-task") ?? [])].map((row) => [
    row.querySelector(".acpmux-chat-inspector-task__command")?.textContent,
    row.querySelector(".acpmux-chat-inspector-task__time")?.textContent ?? null,
    row.querySelector("button.acpmux-chat-inspector-stop") !== null,
  ]);

test("the registry's records carry the call that started them", () => {
  const [record] = processesOf({ processes: [wire("a", "bun run dev", "running", 1_000)] }, "s1");
  expect(record!.toolCallId).toBe("call-a");
});

test("a transcript task the registry lists is listed once, as the registry says it stands", () => {
  const processes = processesOf(
    { processes: [wire("a", "bun run dev", "killed", 1_000, 5_000), wire("b", "tsc --watch", "running", 2_000)] },
    "s1",
  );
  const transcript = [task("call-a", "bun run dev", "running", 1_000), task("call-c", "pytest -x", "completed")];
  expect(
    backgroundCommands(processes, transcript, true).map((command) => [
      command.id,
      command.state,
      command.processId,
      command.toolCallId,
    ]),
  ).toEqual([
    ["s1/a", "stopped", "s1/a", "call-a"],
    ["s1/b", "running", "s1/b", "call-b"],
    // Known only to the transcript: no Stop, but its terminal still opens.
    ["call-c", "completed", undefined, "call-c"],
  ]);
});

test("running commands come first, newest first; the finished follow, newest first", () => {
  const commands = backgroundCommands(
    processesOf(
      {
        processes: [
          wire("old", "tsc --watch", "running", 1_000),
          wire("done", "cargo build", "exited", 2_000, 3_000),
          wire("new", "bun run dev", "running", 5_000),
          wire("lost", "tail -f log", "lost", 4_000, 6_000),
        ],
      },
      "s1",
    ),
    [],
    true,
  );
  const { running, finished } = splitCommands(commands);
  expect(running.map((command) => command.command)).toEqual(["bun run dev", "tsc --watch"]);
  expect(finished.map((command) => [command.command, command.state])).toEqual([
    ["tail -f log", "lost"],
    ["cargo build", "completed"],
  ]);
});

test("a background Bash only the transcript knows is a running task, without Stop", async () => {
  setSystemTime(new Date(100_000));
  const container = installDom();
  // The registry has not listed the chat (an older acpmux, a peer's chat): the transcript is all
  // there is. Ctrl-B moved `pytest -x` to the background; it says when it started.
  await renderInspector(container, {
    processes: [],
    transcriptTasks: [task("call-p", "pytest -x", "running", 100_000 - 12_000), task("call-q", "make docs", "running")],
    onStopProcess: async () => undefined,
  });
  expect(taskRows(container)).toEqual([
    ["pytest -x", "12s", false],
    // No start time: it says it runs.
    ["make docs", "Running", false],
  ]);
  expect(meta(section(container, "tasks"))).toBe("2 running");
  // One that finished folds under the count with how it ended.
  await renderInspector(container, { transcriptTasks: [task("call-r", "cargo test", "failed", 1_000)] });
  const tasks = section(container, "tasks")!;
  expect(taskRows(container)).toEqual([]);
  await click(tasks.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-fold")!);
  expect(
    [...tasks.querySelectorAll<HTMLElement>("[data-finished] .acpmux-chat-inspector-task")].map(
      (row) => row.querySelector(".acpmux-chat-inspector-task__state")?.textContent,
    ),
  ).toEqual(["Failed"]);
});

test("once the registry has listed the chat, a stale transcript task it does not know is not left running", async () => {
  setSystemTime(new Date(100_000));
  const container = installDom();
  const transcript = [
    task("call-x", "npm run watch", "running", 1_000),
    task("call-a", "cargo watch", "running", 1_000),
  ];
  const processes = processesOf({ processes: [wire("a", "cargo watch", "running", 100_000 - 5_000)] }, "s1");
  await renderInspector(container, {
    processes,
    transcriptTasks: transcript,
    listed: true,
    onStopProcess: async () => 0,
  });
  // `call-a` is the registry's process, listed once with its Stop; `call-x` it does not run.
  expect(taskRows(container)).toEqual([["cargo watch", "5s", true]]);
  // Before the listing, the transcript's still shows.
  await renderInspector(container, { processes, transcriptTasks: transcript, onStopProcess: async () => 0 });
  expect(taskRows(container)).toEqual([
    ["cargo watch", "5s", true],
    ["npm run watch", "1m 39s", false],
  ]);
});

test("a task row opens its terminal beside the chat, a running one and a finished one", async () => {
  const container = installDom();
  const posted = recordNative();
  await renderInspector(container, {
    processes: processesOf({ processes: [wire("a", "cargo test", "exited", 1_000, 9_000)] }, "s1"),
    transcriptTasks: [task("call-p", "pytest -x", "running", 1_000)],
    onStopProcess: async () => undefined,
  });
  const tasks = section(container, "tasks")!;
  const open = (command: string) =>
    [...tasks.querySelectorAll<HTMLButtonElement>("button.acpmux-chat-inspector-task__open")].find(
      (button) => button.querySelector(".acpmux-chat-inspector-task__command")?.textContent === command,
    )!;
  await click(open("pytest -x"));
  await click(tasks.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-fold")!);
  await click(open("cargo test"));
  expect(posted.filter((post) => post.method === "chat.processTerminal").map((post) => post.params)).toEqual([
    { toolCallId: "call-p" },
    { toolCallId: "call-a" },
  ]);
  // Stop is its own button: it never opens the terminal.
});

test("Stop shows only on a running command the registry lists", async () => {
  const container = installDom();
  const posted = recordNative();
  const stopped: string[] = [];
  await renderInspector(container, {
    processes: processesOf({ processes: [wire("a", "cargo watch", "running", 1_000)] }, "s1"),
    transcriptTasks: [task("call-p", "pytest -x", "running", 2_000)],
    onStopProcess: async (id) => void stopped.push(id),
  });
  expect(taskRows(container).map(([command, , stop]) => [command, stop])).toEqual([
    ["pytest -x", false],
    ["cargo watch", true],
  ]);
  await click(section(container, "tasks")!.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-stop")!);
  expect(stopped).toEqual(["s1/a"]);
  expect(posted.filter((post) => post.method === "chat.processTerminal")).toEqual([]);
  // Without a way to stop, none at all.
  await renderInspector(container, {
    processes: processesOf({ processes: [wire("a", "cargo watch", "running", 1_000)] }, "s1"),
  });
  expect(section(container, "tasks")!.querySelector("button.acpmux-chat-inspector-stop")).toBeNull();
});

test("a transcript task a running server stands for is listed once, as the server", async () => {
  const container = installDom();
  await renderInspector(container, {
    processes: processesOf({ processes: [wire("a", "bun run dev --port 5173", "running", 1_000)] }, "s1"),
    transcriptTasks: [task("call-a", "bun run dev --port 5173", "running", 1_000)],
  });
  const tasks = section(container, "tasks")!;
  expect(tasks.querySelectorAll(".acpmux-chat-inspector-server")).toHaveLength(1);
  expect(tasks.querySelectorAll(".acpmux-chat-inspector-task")).toHaveLength(0);
});
