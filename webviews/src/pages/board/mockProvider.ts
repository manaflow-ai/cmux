// An in-memory board host for the dev loop, the gallery, the tests and the perf harness. It answers
// `cmux.board.*` like the host will: the snapshot, the change stream (optionally a steady stream of
// generated changes, `ratePerSecond`), Stop (the machine pauses) and Open.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { fixtureBoard, fixtureUpdates } from "./fixtures";
import { BoardOps, type BoardEvent, type BoardSnapshot, type TeamMachine } from "./types";

export interface MockBoardOptions {
  machines?: number;
  seed?: number;
  snapshot?: BoardSnapshot;
  /** Generated changes a second, sent on a timer (0: none). */
  ratePerSecond?: number;
}

export class MockBoardProvider implements PageClient {
  readonly calls: { op: string; params: unknown }[] = [];
  private snapshot: BoardSnapshot;
  private listeners = new Set<(event: BoardEvent) => void>();
  private timer?: ReturnType<typeof setInterval>;
  /** What Stop answers: the paused machine, or a refusal (a test sets it). */
  stopRefusal?: string;
  /** Holds Stop's answer until `release` (a test reads the row while the host is busy). */
  private hold?: Promise<void>;
  private release?: () => void;

  constructor(private readonly options: MockBoardOptions = {}) {
    this.snapshot = options.snapshot ?? fixtureBoard({ machines: options.machines ?? 100, seed: options.seed ?? 1 });
  }

  holdStop(): void {
    this.hold = new Promise((resolve) => (this.release = resolve));
  }

  finishStop(): void {
    this.release?.();
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    const machineId = (params as { machine?: unknown } | null)?.machine;
    switch (op) {
      case BoardOps.snapshot:
        return this.snapshot as R;
      case BoardOps.stop: {
        await this.hold;
        if (this.stopRefusal) throw pageError("cloud.machine.busy", this.stopRefusal);
        const machine = this.snapshot.machines.find((one) => one.id === machineId);
        if (!machine) throw pageError("cloud.machine.not_found", `no machine ${String(machineId)}`);
        const paused: TeamMachine = { ...machine, state: "paused", cost: { ...machine.cost, runningSince: null } };
        this.snapshot = {
          ...this.snapshot,
          machines: this.snapshot.machines.map((one) => (one.id === paused.id ? paused : one)),
        };
        return paused as R;
      }
      case BoardOps.open:
        return { opened: true } as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== BoardOps.changes) throw pageError("cmux.op.unknown", stream);
    const listener = (event: BoardEvent) => onEvent(event as E, 0);
    this.listeners.add(listener);
    this.startStream();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stopStream();
    };
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** Sends one event, as the host does on a change. */
  push(event: BoardEvent): void {
    for (const listener of this.listeners) listener(event);
  }

  private startStream(): void {
    const rate = this.options.ratePerSecond ?? 0;
    if (rate <= 0 || this.timer) return;
    // One tick every 10 ms carries rate/100 events, so 100 a second arrive as 100 separate messages.
    const perTick = Math.max(1, Math.round(rate / 100));
    const interval = rate >= 100 ? 10 : Math.round(1000 / rate);
    let seed = 2;
    this.timer = setInterval(() => {
      for (const event of fixtureUpdates(this.snapshot, perTick, seed++)) this.push(event);
    }, interval);
  }

  private stopStream(): void {
    clearInterval(this.timer);
    this.timer = undefined;
  }
}
