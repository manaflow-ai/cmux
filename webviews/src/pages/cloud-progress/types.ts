// The Cloud progress page's ops (cmux-page://cmux.cloud-progress/): the app answers them from one
// Cloud creation (CloudProgressPageProvider in CloudProgressPage.swift), the window content of a
// New Cloud Workspace or of a window on a paused machine's workspace until its terminal opens.

export const CloudProgressOps = {
  /** `{}` → `CloudProgressState`. */
  state: "cmux.cloudProgress.state",
  /** Stream: one empty event whenever the stage, the machine's name or the opened workspace changed. */
  changes: "cmux.cloudProgress.changes",
  /** `{}` → `{}`: Retry (or Resume on a paused machine). Only after the person's own click or key. */
  retry: "cmux.cloudProgress.retry",
  /** `{}` → `{}`: Dismiss. Only after the person's own click or key. */
  dismiss: "cmux.cloudProgress.dismiss",
  /** `{}` → `{}`: copies the failure. Only after the person's own click or key. */
  copyError: "cmux.cloudProgress.copyError",
  /** `{id, accept}` → `{}`: answers the open `ask`. Only after the person's own click or key. */
  answer: "cmux.cloudProgress.answer",
} as const;

/** `CloudMachineStage.name`: where the machine is on its way to an open terminal. */
export type CloudStage =
  | "requesting"
  | "creating"
  | "booting"
  | "connecting"
  | "ready"
  | "paused"
  | "pausing"
  | "resuming"
  | "deleting"
  | "failed";

/**
 * A question the creation asks on its page instead of a sheet (CloudProgressAsk): an agent's or a
 * script's create asks first, the backend holds the create for approval, or a plan refusal offers
 * the upgrade. The host has the words.
 */
export interface CloudProgressAsk {
  id: string;
  kind: "createRequest" | "approval" | "upgrade";
  title: string;
  body: string;
  /** The yes button (Create, Upgrade). */
  button: string;
  /** The no button. */
  cancel: string;
}

export interface CloudProgressState {
  stage: CloudStage;
  /** The stage's place in `steps`, or the last step reached while it fails or pauses. */
  step: number;
  /** The stages of the list, in order (`CloudMachineStage.steps`). */
  steps: CloudStage[];
  /** Why it stopped, in the host's words; null unless `stage` is `failed`. */
  failure: string | null;
  /** Paused by the idle auto-pause. */
  idle: boolean;
  /** The machine's name once it exists. */
  machine: string | null;
  /** Time since the attempt started (or until it was ready) when the host answered. */
  elapsedMs: number;
  /** Ready, paused or failed: the elapsed line stops. */
  finished: boolean;
  /** The open question, if one is. */
  ask: CloudProgressAsk | null;
}
