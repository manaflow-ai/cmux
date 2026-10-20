// The Inspector's Background tasks and Servers (Claude Code desktop's): the chat's background
// processes from acpmux's registry (`_acpmux/process/list` and `process_update`). Dev servers go
// under Servers with the ports their commands name; the rest under Background tasks, running ones
// with their elapsed time and a Stop button, then "N finished", folded.
import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { resetInspectorState } from "../src/agent-session/acpmux/inspector/inspectorState";
import {
  mergeProcess,
  processesOf,
  serverOf,
  splitServers,
  useInspectorProcesses,
  type InspectorProcess,
  type ProcessSource,
} from "../src/agent-session/acpmux/inspector/processes";

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
  container.querySelector<HTMLElement>(`section.acpmux-inspector-section[data-section="${id}"]`);
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
  expect(section(container, "servers")).toBeNull();

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
  const rows = () => [...tasks.querySelectorAll<HTMLElement>(".acpmux-inspector-task")];
  // Running first, newest first.
  expect(rows().map((row) => row.querySelector(".acpmux-inspector-task__command")?.textContent)).toEqual([
    "cargo watch -x check",
    "tsc --watch",
  ]);
  expect(rows().map((row) => row.querySelector(".acpmux-inspector-task__time")?.textContent)).toEqual([
    "1m 16s",
    "1h 2m 3s",
  ]);
  expect(tasks.querySelector(".acpmux-inspector-section__meta")?.textContent).toBe("2 running");

  // The finished ones fold behind their count; open, each with how long it ran and how it ended.
  const fold = tasks.querySelector<HTMLButtonElement>("button.acpmux-inspector-fold")!;
  expect(fold.textContent).toBe("2 finished");
  expect(fold.getAttribute("aria-expanded")).toBe("false");
  await click(fold);
  const finished = [...tasks.querySelectorAll<HTMLElement>("[data-finished] .acpmux-inspector-task")];
  expect(finished.map((row) => row.querySelector(".acpmux-inspector-task__state")?.textContent)).toEqual([
    "Finished",
    "Failed",
  ]);

  const stop = rows()[0]!.querySelector<HTMLButtonElement>("button.acpmux-inspector-stop")!;
  expect(stop.getAttribute("aria-label")).toBe("Stop cargo watch -x check");
  await click(stop);
  expect(stopped).toEqual(["s1/a"]);
  // It waits for the registry's update rather than dropping the row itself.
  expect(stop.disabled).toBe(true);
});

test("a dev server is listed under Servers with its port, which opens beside the chat, and Stop", async () => {
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
  expect(section(container, "tasks")).toBeNull();
  const servers = section(container, "servers")!;
  expect(servers.querySelector(".acpmux-inspector-section__meta")?.textContent).toBe("1 running");
  const port = servers.querySelector<HTMLButtonElement>("button.acpmux-inspector-port")!;
  expect(port.textContent).toBe(":5173");
  expect(port.getAttribute("aria-label")).toBe("Open http://localhost:5173");
  await click(port);
  expect(opened).toEqual(["http://localhost:5173"]);
  await click(servers.querySelector<HTMLButtonElement>("button.acpmux-inspector-stop")!);
  expect(stopped).toEqual(["s1/a"]);
});

test("a session whose processes all finished keeps the section with only its count", async () => {
  const container = installDom();
  await render(container, processesOf({ processes: [wire("b", "cargo test", "exited", 1_000, 9_000)] }, "s1"));
  const tasks = section(container, "tasks")!;
  expect(tasks.querySelectorAll(".acpmux-inspector-task")).toHaveLength(0);
  expect(tasks.querySelector("button.acpmux-inspector-fold")?.textContent).toBe("1 finished");
  // No Stop without a way to stop.
  expect(tasks.querySelector("button.acpmux-inspector-stop")).toBeNull();
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
  const stop = () => section(container, "tasks")!.querySelector<HTMLButtonElement>("button.acpmux-inspector-stop")!;
  await act(async () => stop().click());
  expect(stop().getAttribute("data-state")).toBe("failed");
  expect(stop().getAttribute("aria-label")).toBe("Couldn’t stop cargo watch");
  expect(stop().disabled).toBe(false);
  refuse = false;
  await act(async () => stop().click());
  expect(stop().getAttribute("data-state")).toBe("stopping");
});
