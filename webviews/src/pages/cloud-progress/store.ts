// The Cloud progress page's state owner: the host's creation state, read again on every change event
// (no polling). React reads it through `useSyncExternalStore`; a reply older than a newer read is
// dropped. `receivedAt` is when the shown state arrived, so the page's elapsed line counts on from
// the host's `elapsedMs` without asking again.
import type { PageClient } from "../shared/pageClient";
import { CloudProgressOps, type CloudProgressState } from "./types";

export interface CloudProgressSnapshot {
  state?: CloudProgressState;
  /** `Date.now()` when `state` arrived. */
  receivedAt: number;
  /** The page has no host to ask. */
  unavailable?: boolean;
}

export type CloudProgressAction = "retry" | "dismiss" | "copyError";

export class CloudProgressStore {
  private snapshot: CloudProgressSnapshot = { receivedAt: 0 };
  private readonly listeners = new Set<() => void>();
  private request = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(
    private readonly client: PageClient | null,
    private readonly now: () => number = Date.now,
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** Follows the host's change events, then reads the state once. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ receivedAt: this.now(), unavailable: true });
    try {
      const stop = await this.client.subscribe(CloudProgressOps.changes, () => void this.refresh());
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the page still shows the state it read on open.
    }
    await this.refresh();
  }

  stop(): void {
    this.stopped = true;
    this.stopChanges?.();
    this.stopChanges = undefined;
  }

  async refresh(): Promise<void> {
    if (!this.client) return;
    const id = ++this.request;
    try {
      const state = await this.client.call<CloudProgressState>(CloudProgressOps.state, {});
      if (id === this.request) this.set({ state, receivedAt: this.now() });
    } catch {
      // The last state stays; the next change event reads again.
    }
  }

  /** Retry (Resume), Dismiss or Copy Error; the host takes them only from the person's own click or key. */
  async run(action: CloudProgressAction): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(CloudProgressOps[action], {});
    } catch {
      // A refused or failed action changes nothing; the stage the host shows next says what happened.
    }
  }

  /** Answers the open question; the host takes it only from the person's own click or key. */
  async answer(id: string, accept: boolean): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(CloudProgressOps.answer, { id, accept });
    } catch {
      // A refused answer leaves the question open; the next change event shows where it stands.
    }
  }

  private set(next: CloudProgressSnapshot) {
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }
}

/** Milliseconds as the elapsed line's clock: `0:05`, `1:30`, `12:04`. */
export function elapsedClock(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** The catalog key of a stage's name (`cloudProgress.stage.`) or next line (`cloudProgress.next.`). */
export function stageKey(state: Pick<CloudProgressState, "stage" | "idle">): string {
  return state.stage === "paused" && state.idle ? "pausedIdle" : state.stage;
}

/** Each step's mark: done, the current one, the one a failure stopped at, or still to come. */
export type StepMark = "done" | "current" | "failed" | "next";

export function stepMarks(state: CloudProgressState): StepMark[] {
  return state.steps.map((_, index) => {
    if (state.stage === "failed" && index === state.step) return "failed";
    if (index < state.step || state.stage === "ready") return "done";
    if (index === state.step && state.stage !== "paused") return "current";
    return "next";
  });
}
