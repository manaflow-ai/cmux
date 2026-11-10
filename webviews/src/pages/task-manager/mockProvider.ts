// l10n-allow-file: mock host fixtures (sample processes), not shipped UI.
// An in-memory Task Manager host for the browser dev loop (`/task-manager/?mock`) and the gallery:
// one fixed snapshot on the `snapshot` stream, and the calls recorded.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { TaskManagerOps, type TaskManagerRow, type TaskManagerSnapshot } from "./types";

const MB = 1024 * 1024;

function row(
  pid: number,
  task: string,
  name: string,
  cpu: number | null,
  memoryMB: number,
  refusal: string | null = null,
  host = "local",
): TaskManagerRow {
  return {
    id: `${host}:${pid}`,
    host,
    pid,
    task,
    name,
    cpu,
    cpuText: cpu === null ? "–" : `${(cpu * 100).toFixed(1)}%`,
    memoryBytes: memoryMB * MB,
    memoryText: memoryMB >= 1024 ? `${(memoryMB / 1024).toFixed(2)} GB` : `${memoryMB.toFixed(1)} MB`,
    refusal,
  };
}

const APP_REFUSAL = "Kill Process does not end cmux itself. Quit cmux instead.";
const DAEMON_REFUSAL = "Kill Process does not end the cmux daemon: every terminal it runs would end.";
const REMOTE_REFUSAL = "Kill Process ends only processes on this Mac.";

/** A working window: the app, a daemon, Chromium's shared processes and a few tabs. */
export function normalSnapshot(): TaskManagerSnapshot {
  return {
    revision: 12,
    rows: [
      row(501, "cmux", "cmux", 0.062, 412.4, APP_REFUSAL),
      row(502, "cmux daemon", "cmux-tui", 0.011, 38.2, DAEMON_REFUSAL),
      row(611, "GPU", "cmux Helper (GPU)", 0.034, 188.6),
      row(612, "Network", "cmux Helper", 0.002, 22.1),
      row(733, "atlas-web", "zsh", 0, 4.6),
      row(734, "atlas-web", "bun", 0.218, 236.9),
      row(801, "Release notes, TypeScript handbook", "cmux Helper (Renderer)", 0.041, 142.3),
      row(902, "Settings", "com.apple.WebKit.WebContent", 0.004, 61.7),
    ],
    total: "CPU 37.2% · Memory 1.08 GB",
  };
}

/** The first sample: no CPU yet. */
export function firstSampleSnapshot(): TaskManagerSnapshot {
  const snapshot = normalSnapshot();
  return {
    revision: 1,
    rows: snapshot.rows.map((entry) => ({ ...entry, cpu: null, cpuText: "–" })),
    total: "CPU – · Memory 1.08 GB",
  };
}

/** A busy machine: many terminals, renderers and a remote machine's processes. */
export function manyRowsSnapshot(): TaskManagerSnapshot {
  const rows = [...normalSnapshot().rows];
  for (let index = 0; index < 48; index++) {
    const pid = 2000 + index * 7;
    const tab = `workspace ${String.fromCharCode(97 + (index % 26))}${Math.floor(index / 26) + 1}`;
    const kinds = ["zsh", "node", "cargo", "cmux Helper (Renderer)"];
    const seed = (index * 2_654_435_761) % 997;
    rows.push(row(pid, tab, kinds[index % kinds.length], (seed % 300) / 1000, 8 + (seed % 900) / 3));
  }
  rows.push(row(4242, "cmux daemon", "cmux-tui", 0.008, 41.3, REMOTE_REFUSAL, "m-cloud"));
  return { revision: 340, rows, total: "CPU 812.4% · Memory 9.87 GB" };
}

export class MockTaskManagerProvider implements PageClient {
  readonly calls: { op: string; params: unknown }[] = [];

  constructor(private readonly snapshot: TaskManagerSnapshot = normalSnapshot()) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (op !== TaskManagerOps.select && op !== TaskManagerOps.kill) throw pageError("cmux.protocol.unknown_op", op);
    this.calls.push({ op, params });
    return {} as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== TaskManagerOps.snapshot) throw pageError("cmux.protocol.unknown_op", stream);
    onEvent(this.snapshot as E, 0);
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}
