// l10n-allow-file: test fixtures, not shipped UI.
// While no list of a chat's whole process history shows, its page holds only a window of it
// (session-info/processes.ts `useProcessRegistry`, acpmux `recent` and `calls`): a god chat ran
// 56,000 shells, and the page held all of them for a tray of a few (2026-11-16). Review of cmux#44893
// refused it as a strict fix: "chats with more than 500 ended processes now show only the newest 500
// in the tray and summary card". What the page shows must be the whole history's; only the cost may
// change. These check, at more than PROCESS_LIST_RECENT ended processes, that the counts the card and
// the palette read (App.tsx `backgroundRows`: the chat's and a subagent view's) and the tray's ended
// commands are the ones the whole list gives.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { SummaryBackgroundTask } from "../src/agent-session/acpmux/summary/sessionSummary";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const processes = await import("../src/agent-session/acpmux/session-info/processes");
const { backgroundCommands, backgroundRowCount, PROCESS_LIST_RECENT, useProcessRegistry } = processes;
type ProcessRegistry = import("../src/agent-session/acpmux/session-info/processes").ProcessRegistry;
type ProcessSource = import("../src/agent-session/acpmux/session-info/processes").ProcessSource;
type RegistryWindow = import("../src/agent-session/acpmux/session-info/processes").RegistryWindow;
type SessionInfoProcess = import("../src/agent-session/acpmux/session-info/processes").SessionInfoProcess;
const { callIds, subagentProcesses } = await import("../src/agent-session/acpmux/session-info/subagentScope");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const NOW = Date.UTC(2026, 10, 17, 12, 0, 0);
const COUNT = 2_000;
const WITHIN = 240_000;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/// Process `n` of a chat that ran COUNT: every 400th still runs, process 3 is a dev server, and
/// process 0, the oldest, ended a moment ago (an old one that ended last).
function processAt(n: number) {
  const running = n % 400 === 7 || n === 3;
  return {
    id: `${CHAT}/task-${n}`,
    sessionId: CHAT,
    toolCallId: `call-${n}`,
    command: n === 3 ? "npm run dev -- --port 5173" : `make case-${n}`,
    state: running ? "running" : "exited",
    startedAt: NOW - 10_000_000 + n * 1_000,
    ...(running ? {} : { endedAt: n === 0 ? NOW - 5_000 : NOW - 10_000_000 + n * 1_000 + 500 }),
  };
}

/// A stand-in acpmux answering as hub/processes.rs does: `recent` by end with `endedBefore`,
/// `calls` with `answered`, the whole list without either. `asked` records each read.
function daemon(all = Array.from({ length: COUNT }, (_, n) => processAt(n))) {
  const asked: Record<string, unknown>[] = [];
  let listener: ((value: unknown) => void) | undefined;
  const end = (p: { endedAt?: number }) => p.endedAt ?? 0;
  const source: ProcessSource = {
    async listProcesses(sessionId, recent, endedWithin) {
      asked.push({ sessionId, recent, endedWithin });
      if (recent === undefined) return { processes: all };
      const ends = all
        .filter((p) => p.state !== "running")
        .map(end)
        .sort((a, b) => b - a);
      let cutoff = ends.length <= recent ? 0 : ends[recent - 1]!;
      if (endedWithin !== undefined) cutoff = Math.min(cutoff, NOW - endedWithin);
      const kept = all.filter((p) => p.state === "running" || end(p) >= cutoff);
      const omitted = all.length - kept.length;
      return { processes: kept, recent, ...(omitted > 0 ? { omitted, endedBefore: cutoff } : {}) };
    },
    async listProcessCalls(sessionId, calls) {
      asked.push({ sessionId, calls: [...calls] });
      const wanted = new Set(calls);
      return all.filter((p) => wanted.has(p.toolCallId));
    },
    watchProcesses(next) {
      listener = next;
      return () => {
        listener = undefined;
      };
    },
  };
  return { source, asked, all, send: (value: unknown) => listener?.(value) };
}

const task = (id: string, state: SummaryBackgroundTask["state"] = "completed"): SummaryBackgroundTask => ({
  id,
  command: `make ${id}`,
  state,
});
/// The transcript's background tasks: two whose processes are long ended and left out of the
/// window, one recent, one the registry never had, one it never had that still says it runs.
const TRANSCRIPT = [
  task("call-10"),
  task("call-11", "failed"),
  task("call-1999"),
  task("call-x"),
  task("call-y", "running"),
];
/// A subagent view whose calls started three old processes and a recent one (and one plain call).
const SUBAGENT_ROWS = [
  { kind: "activity", items: [{ tool: { id: "call-20" } }, { tool: { id: "call-21" } }, { tool: { id: "read-1" } }] },
  { kind: "activity", items: [{ tool: { id: "call-22" } }, { tool: { id: "call-1990" } }] },
] as unknown as AcpmuxRow[];
const SUBAGENT_TASKS = [task("call-20"), task("call-1990")];

/// The registry as App.tsx holds it for a window of `calls` (none: the whole list).
async function registryOf(source: ProcessSource, window?: RegistryWindow) {
  const seen: { registry?: ProcessRegistry; window?: RegistryWindow } = { window };
  function Probe() {
    seen.registry = useProcessRegistry(source, CHAT, true, seen.window);
    return null;
  }
  const settle = async () => {
    for (let n = 0; n < 10; n += 1) await act(tick);
  };
  root = createRoot(host);
  await act(async () => root!.render(<Probe />));
  await settle();
  /// The same registry drawn again with `next` as its window.
  const redraw = async (next?: RegistryWindow) => {
    seen.window = next;
    await act(async () => root!.render(<Probe />));
    await settle();
  };
  return { seen, redraw };
}

const chatCount = (registry: ProcessRegistry, transcript = TRANSCRIPT) =>
  backgroundRowCount(registry.processes, transcript, registry.listed, registry.omitted ?? 0);
const subagentCount = (registry: ProcessRegistry) =>
  backgroundRowCount(subagentProcesses(registry.processes, SUBAGENT_ROWS), SUBAGENT_TASKS, registry.listed);
const callsOf = (transcript: readonly SummaryBackgroundTask[], rows?: readonly AcpmuxRow[]) => [
  ...new Set([...transcript.map((t) => t.id), ...(rows ? callIds(rows) : [])]),
];
const endedKeys = (registry: ProcessRegistry, transcript = TRANSCRIPT) =>
  backgroundCommands(registry.processes, transcript, registry.listed)
    .filter((command) => command.state !== "running")
    .map((command) => `${command.toolCallId ?? command.id}|${command.state}|${command.endedAt ?? ""}`);

test("the card's count is the whole history's, for the chat and for a subagent's view, past 500 ended", async () => {
  const whole = daemon();
  const all = (await registryOf(whole.source)).seen.registry!;
  expect(all.processes).toHaveLength(COUNT);
  root!.unmount();

  const window = daemon();
  const { seen } = await registryOf(window.source, {
    calls: callsOf(TRANSCRIPT, SUBAGENT_ROWS),
    endedWithin: WITHIN,
  });
  const held = seen.registry!;
  // The window holds far less than the history ...
  expect(held.processes.length).toBeLessThan(PROCESS_LIST_RECENT + 20);
  expect(held.omitted).toBeGreaterThan(1_000);
  // ... and counts what the whole list counts.
  expect(chatCount(held)).toBe(chatCount(all));
  expect(subagentCount(held)).toBe(subagentCount(all));
  expect(window.asked[0]).toEqual({ sessionId: CHAT, recent: PROCESS_LIST_RECENT, endedWithin: WITHIN });
});

test("the tray's ended commands differ from the whole list's only by ones that ended before its linger", async () => {
  const all = (await registryOf(daemon().source)).seen.registry!;
  root!.unmount();
  const held = (await registryOf(daemon().source, { calls: callsOf(TRANSCRIPT), endedWithin: WITHIN })).seen.registry!;
  const shown = new Set(endedKeys(held));
  const wholeKeys = endedKeys(all);
  // Nothing shows that the whole list would not show (a transcript task its process stands for).
  for (const key of shown) expect(wholeKeys).toContain(key);
  // What the window leaves out ended before the tray's linger, so the tray never shows it
  // (subagents/trayLinger.ts: an ended line it never saw run shows only within its grace).
  for (const key of wholeKeys.filter((key) => !shown.has(key))) {
    const ended = Number(key.split("|")[2]);
    expect(NOW - ended).toBeGreaterThan(WITHIN);
  }
  // The old process that ended a moment ago is one the window holds.
  expect(shown.has(`call-0|completed|${NOW - 5_000}`)).toBe(true);
});

test("calls the transcript gains later are read, and the count follows the whole list's", async () => {
  const fake = daemon();
  const window = { calls: callsOf(TRANSCRIPT), endedWithin: WITHIN };
  const { seen, redraw } = await registryOf(fake.source, window);
  const all = (await daemon().source.listProcesses(CHAT)) as { processes: SessionInfoProcess[] };
  const older = [...TRANSCRIPT, task("call-30"), task("call-31")];
  // Older rows read: two more old shells.
  await redraw({ calls: callsOf(older), endedWithin: WITHIN });
  expect(fake.asked.at(-1)).toEqual({ sessionId: CHAT, calls: ["call-30", "call-31"] });
  expect(fake.asked.filter((read) => "recent" in read)).toHaveLength(1);
  expect(chatCount(seen.registry!, older)).toBe(backgroundRowCount(all.processes, older, true));
});

test("an update to a left-out process and a new one that ends at once keep the count exact", async () => {
  const fake = daemon();
  const { seen } = await registryOf(fake.source, { calls: callsOf(TRANSCRIPT), endedWithin: WITHIN });
  const before = chatCount(seen.registry!);
  // An old shell's output file named late: the same process, no new row.
  await act(async () => fake.send({ ...processAt(40), outputBytes: 12 }));
  expect(chatCount(seen.registry!)).toBe(before);
  // A new shell reported already ended: one more row.
  await act(async () =>
    fake.send({ ...processAt(COUNT), id: `${CHAT}/task-new`, toolCallId: "call-new", endedAt: NOW }),
  );
  expect(chatCount(seen.registry!)).toBe(before + 1);
});

test("a source that cannot read calls is read whole", async () => {
  const fake = daemon();
  const refusing: ProcessSource = {
    ...fake.source,
    listProcessCalls: () => Promise.reject(new Error("calls not read")),
  };
  const { seen } = await registryOf(refusing, { calls: callsOf(TRANSCRIPT), endedWithin: WITHIN });
  expect(seen.registry!.processes).toHaveLength(COUNT);
  expect(seen.registry!.omitted ?? 0).toBe(0);
});
