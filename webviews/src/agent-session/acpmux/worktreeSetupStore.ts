// The worktrees this pane made whose setup it follows (design/worktree-setup.md), kept apart from
// the line's view so New Worktree's model can remember one without the view.
import { setupState, type WorktreeSetupState } from "../../worktreeRecipe";

/** What `git.worktree.create` said about the setup it started. */
export type WorktreeSetupStart = { state: WorktreeSetupState; port?: number };

// The worktrees this pane made whose setup it follows, by root. A chat in one of these folders
// shows the line; Dismiss, or leaving a chat whose setup is over, forgets it.
const started = new Map<string, WorktreeSetupStart>();
const listeners = new Set<() => void>();
let version = 0;
const changed = () => {
  version += 1;
  for (const listener of listeners) listener();
};

/** Remembers a setup `git.worktree.create` started (state `none`: nothing to follow). */
export function rememberWorktreeSetup(root: string, setup: unknown): WorktreeSetupStart | undefined {
  const value = (setup && typeof setup === "object" ? setup : {}) as { state?: unknown; port?: unknown };
  const state = setupState(value.state);
  if (state === "none") return undefined;
  const start: WorktreeSetupStart = { state, ...(typeof value.port === "number" ? { port: value.port } : {}) };
  started.set(root, start);
  changed();
  return start;
}

export function forgetWorktreeSetup(root: string): void {
  if (started.delete(root)) changed();
}

export function startedWorktreeSetup(folder: string): WorktreeSetupStart | undefined {
  return started.get(folder);
}

export function subscribeWorktreeSetups(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function worktreeSetupsVersion(): number {
  return version;
}
