import type { HeaderPullRequest } from "./headerState";

export type PullRequestActionName = "state" | "fixChecks" | "addressComments" | "arm";
export type PullRequestAction = (
  pr: HeaderPullRequest,
  action: PullRequestActionName,
  signal: AbortSignal,
) => Promise<HeaderPullRequest>;
interface View {
  head?: HeaderPullRequest;
  busy?: PullRequestActionName;
  message?: string;
}
let nextGeneration = 0;

// Presentation and request lifetime only. Rust owns all PR reads and action policy.
export class PullRequestActionView {
  readonly generation = ++nextGeneration;
  private view: View = {};
  private lifetime?: AbortController;
  private listeners = new Set<() => void>();
  constructor(
    readonly initial?: HeaderPullRequest,
    readonly scope = "",
  ) {}
  snapshot = () => this.view;
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  private update(view: View) {
    this.view = view;
    this.listeners.forEach((listener) => listener());
  }
  activate() {
    this.lifetime = new AbortController();
    this.update({ head: this.view.head });
  }
  dispose() {
    this.lifetime?.abort();
    this.lifetime = undefined;
  }
  async invoke(action: PullRequestActionName, run: PullRequestAction, fallback: string) {
    const lifetime = this.lifetime;
    const displayed = this.view.head ?? this.initial;
    if (!lifetime || !displayed || this.view.busy || (action !== "state" && !this.view.head?.headSha)) return;
    this.update({ ...this.view, busy: action, message: undefined });
    try {
      const head = await run(displayed, action, lifetime.signal);
      if (!lifetime.signal.aborted) this.update({ head });
    } catch (error) {
      if (!lifetime.signal.aborted)
        this.update({
          head: this.view.head,
          message: error instanceof Error ? error.message : fallback,
        });
    }
  }
}
