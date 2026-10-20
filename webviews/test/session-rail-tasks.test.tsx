// The session rail's Background tasks card (Claude Code desktop's): the session's background
// processes from acpmux's registry (`_acpmux/process/list` and `process_update`), running ones
// with their elapsed time and a Stop button, and how many finished.
import { afterEach, expect, setSystemTime, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SessionRail } from "../src/agent-session/acpmux/summary/SessionRail";
import { mergeProcess, processesOf, type RailProcess } from "../src/agent-session/acpmux/summary/sessionProcesses";

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

async function render(container: HTMLElement, processes: readonly RailProcess[], onStop?: (id: string) => Promise<unknown>) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<SessionRail outputs={[]} processes={processes} onStopProcess={onStop} />);
  });
}

const card = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>(".acpmux-rail-card")].find(
    (element) => element.querySelector(".acpmux-rail-card__title")?.textContent === "Background tasks",
  );

test("the registry's records become the session's processes, an update replacing its record", () => {
  const listed = processesOf(
    { processes: [wire("a", "bun run dev", "running", 1_000), wire("b", "cargo test", "exited", 2_000, 9_000)] },
    "s1",
  );
  expect(listed.map((process) => [process.id, process.command, process.state])).toEqual([
    ["s1/a", "bun run dev", "running"],
    ["s1/b", "cargo test", "exited"],
  ]);
  // Another chat's record and a malformed one are dropped.
  expect(processesOf({ processes: [{ ...wire("c", "x", "running", 1), sessionId: "s2" }, { id: 3 }] }, "s1")).toEqual(
    [],
  );
  const stopped = mergeProcess(listed, wire("a", "bun run dev", "killed", 1_000, 5_000), "s1");
  expect(stopped.map((process) => process.state)).toEqual(["killed", "exited"]);
  const added = mergeProcess(stopped, wire("d", "vite", "running", 6_000), "s1");
  expect(added.map((process) => process.id)).toEqual(["s1/a", "s1/b", "s1/d"]);
  expect(mergeProcess(added, { ...wire("e", "y", "running", 1), sessionId: "s2" }, "s1")).toBe(added);
});

test("no card before the first background process; then running ones with elapsed time and Stop, and a finished count", async () => {
  setSystemTime(new Date(100_000));
  const container = installDom();
  await render(container, []);
  expect(card(container)).toBeUndefined();

  const processes = processesOf(
    {
      processes: [
        wire("a", "bun run dev", "running", 100_000 - 76_000),
        wire("b", "cargo test", "exited", 1_000, 9_000),
        wire("c", "tsc --watch", "running", 100_000 - 3_723_000),
        wire("d", "npm run lint", "failed", 1_000, 2_000),
      ],
    },
    "s1",
  );
  const stopped: string[] = [];
  await render(container, processes, async (id) => void stopped.push(id));
  const tasks = card(container)!;
  const rows = [...tasks.querySelectorAll<HTMLElement>(".acpmux-rail-task")];
  // Running first, newest first.
  expect(rows.map((row) => row.querySelector(".acpmux-rail-task__command")?.textContent)).toEqual([
    "bun run dev",
    "tsc --watch",
  ]);
  expect(rows.map((row) => row.querySelector(".acpmux-rail-task__time")?.textContent)).toEqual(["1m 16s", "1h 2m 3s"]);
  expect(tasks.querySelector(".acpmux-rail-card__value")?.textContent).toBe("2 running");
  expect(tasks.querySelector(".acpmux-rail-tasks__finished")?.textContent).toBe("2 finished");

  const stop = rows[0]!.querySelector<HTMLButtonElement>("button.acpmux-rail-task__stop")!;
  expect(stop.getAttribute("aria-label")).toBe("Stop bun run dev");
  await act(async () => stop.click());
  expect(stopped).toEqual(["s1/a"]);
  // It waits for the registry's update rather than dropping the row itself.
  expect(stop.disabled).toBe(true);
});

test("a session whose processes all finished keeps the card with only its count", async () => {
  const container = installDom();
  await render(container, processesOf({ processes: [wire("b", "cargo test", "exited", 1_000, 9_000)] }, "s1"));
  const tasks = card(container)!;
  expect(tasks.querySelectorAll(".acpmux-rail-task")).toHaveLength(0);
  expect(tasks.querySelector(".acpmux-rail-tasks__finished")?.textContent).toBe("1 finished");
  // No Stop without a way to stop.
  expect(tasks.querySelector("button.acpmux-rail-task__stop")).toBeNull();
});
