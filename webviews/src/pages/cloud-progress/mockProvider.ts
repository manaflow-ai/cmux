// l10n-allow-file: mock host data (a sample machine name and failure), not shipped UI.
// An in-memory Cloud creation for the browser dev loop (`/cloud-progress/?mock`) and the gallery: it
// answers `state`, and with `walk` moves through the stages two seconds apart. Retry starts it over;
// Dismiss and Copy Error do nothing here.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { CloudProgressOps, type CloudProgressAsk, type CloudProgressState, type CloudStage } from "./types";

export const CLOUD_STEPS: CloudStage[] = ["requesting", "creating", "booting", "connecting", "ready"];

/** The host's questions, in its words (CloudPresenter.createAsk, offerPro). */
export const SAMPLE_ASKS = {
  createRequest: {
    id: "ask-create",
    kind: "createRequest",
    title: "Create a Cloud machine?",
    body: "An agent asked for a new Cloud machine.\nName: paint-dev\nSize: 2 CPU · 4 GB memory · 16 GB disk",
    button: "Create",
    cancel: "Cancel",
  },
  approval: {
    id: "ask-approval",
    kind: "approval",
    title: "Create a Cloud machine?",
    body: "cmux Cloud needs your approval for this machine.\nName: paint-dev",
    button: "Create",
    cancel: "Cancel",
  },
  upgrade: {
    id: "ask-upgrade",
    kind: "upgrade",
    title: "cmux Pro required",
    body: "Your plan allows no more running machines. cmux Pro runs more at once.",
    button: "Upgrade",
    cancel: "Cancel",
  },
} as const satisfies Record<string, CloudProgressAsk>;

/** A state for `stage`, the step it is at, and the rest made up. */
export function sampleState(stage: CloudStage, change: Partial<CloudProgressState> = {}): CloudProgressState {
  const index = CLOUD_STEPS.indexOf(stage);
  const step = index >= 0 ? index : 3;
  return {
    stage,
    step,
    steps: CLOUD_STEPS,
    failure: stage === "failed" ? "The machine's link closed before cmux-tui answered." : null,
    idle: false,
    machine: index >= 2 || index < 0 ? "paint-dev" : null,
    elapsedMs: 4_000 + step * 9_000,
    finished: stage === "ready" || stage === "paused" || stage === "failed",
    ask: null,
    ...change,
  };
}

export class MockCloudProgressProvider implements PageClient {
  private state: CloudProgressState;
  private readonly listeners = new Set<() => void>();
  private timer?: ReturnType<typeof setTimeout>;

  constructor(options: { state?: CloudProgressState; walk?: boolean } = {}) {
    this.state = options.state ?? sampleState("requesting");
    if (options.walk) this.walk();
  }

  async call<R>(op: string, _params?: unknown): Promise<R> {
    switch (op) {
      case CloudProgressOps.state:
        return this.state as R;
      case CloudProgressOps.retry:
        this.update(sampleState("requesting", { elapsedMs: 0 }));
        this.walk();
        return {} as R;
      case CloudProgressOps.answer:
        this.update({ ...this.state, ask: null });
        return {} as R;
      case CloudProgressOps.dismiss:
      case CloudProgressOps.copyError:
        return {} as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== CloudProgressOps.changes) throw pageError("cmux.op.unknown", stream);
    let seq = 0;
    const listener = () => onEvent({} as E, ++seq);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }

  /** The next stage two seconds from now, until ready (a stop condition: it ends there). */
  private walk() {
    clearTimeout(this.timer);
    const next = CLOUD_STEPS[CLOUD_STEPS.indexOf(this.state.stage) + 1];
    if (!next) return;
    this.timer = setTimeout(() => {
      this.update(sampleState(next));
      this.walk();
    }, 2_000);
  }

  private update(state: CloudProgressState) {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
