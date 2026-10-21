import type { AcpmuxRow } from "../model";

export type RunArtifact = {
  id: string;
  name: string;
  kind: "screenshot" | "recording" | "patch";
  digest: string;
  verified: boolean;
};

export type RunAttempt = {
  id: string;
  label: string;
  direction: string;
  worker: string;
  sessionId: string;
  /** False when the Run API says no terminal is retained to attach to; unset in fixtures. */
  attachable?: boolean;
  state: "running" | "completed" | "failed";
  activity: string;
  build: "pending" | "passed" | "failed";
  tests: { passed: number; failed: number };
  artifacts: RunArtifact[];
  rows: AcpmuxRow[];
};

/** A projection from the Run owner, separate from the existing agent transcript. */
export type RunBoardSnapshot = {
  id: string;
  title: string;
  intent: string;
  source: string;
  cursor: string;
  attempts: RunAttempt[];
};

export type ApprovalIntent = { runId: string; attemptId: string; cursor: string; digests: string[] };

export type AttachTicket = {
  runId: string;
  attemptId: string;
  sessionId: string;
  cursor: string;
  ticket?: string;
  expiresAt?: string | number;
  expiresAtUnix?: number;
};

export type RunBoardState = {
  snapshot: RunBoardSnapshot;
  connection: "live" | "disconnected";
  selected: string;
  attached?: string;
  attachTicket?: AttachTicket;
  reviewed?: string;
  approval?: ApprovalIntent;
};

export type RunBoardAction =
  | { type: "select"; attemptId: string }
  | { type: "attach"; ticket?: AttachTicket }
  | { type: "review"; checked: boolean }
  | { type: "approve" }
  | { type: "disconnect" }
  | { type: "receive"; snapshot: RunBoardSnapshot };

export function initialBoard(snapshot: RunBoardSnapshot, disconnected = false): RunBoardState {
  return { snapshot, selected: snapshot.attempts[0]?.id ?? "", connection: disconnected ? "disconnected" : "live" };
}

export function selectedAttempt(state: RunBoardState): RunAttempt | undefined {
  return state.snapshot.attempts.find((attempt) => attempt.id === state.selected);
}

export function evidenceReady(attempt: RunAttempt): boolean {
  return (
    attempt.state === "completed" &&
    attempt.build === "passed" &&
    attempt.tests.passed > 0 &&
    attempt.tests.failed === 0 &&
    attempt.artifacts.every((artifact) => artifact.verified && artifact.digest.length > 0) &&
    ["screenshot", "recording", "patch"].every((kind) =>
      attempt.artifacts.some((artifact) => artifact.kind === kind && artifact.verified && artifact.digest.length > 0),
    )
  );
}

const evidenceKey = (snapshot: RunBoardSnapshot, attempt: RunAttempt) =>
  JSON.stringify([snapshot.id, attempt.id, snapshot.cursor, attempt.artifacts.map((artifact) => artifact.digest)]);

export function canApprove(state: RunBoardState): boolean {
  const attempt = selectedAttempt(state);
  return Boolean(
    state.connection === "live" &&
    attempt &&
    evidenceReady(attempt) &&
    state.reviewed === evidenceKey(state.snapshot, attempt) &&
    !state.approval,
  );
}

/** Only local selection and human intent live here. The server owns execution and acceptance. */
export function reduceBoard(state: RunBoardState, action: RunBoardAction): RunBoardState {
  const attempt = selectedAttempt(state);
  switch (action.type) {
    case "select":
      return state.snapshot.attempts.some((item) => item.id === action.attemptId)
        ? { ...state, selected: action.attemptId, reviewed: undefined }
        : state;
    case "attach":
      return attempt && state.connection === "live"
        ? { ...state, attached: attempt.id, attachTicket: action.ticket }
        : state;
    case "review":
      return {
        ...state,
        reviewed:
          action.checked && attempt && evidenceReady(attempt) ? evidenceKey(state.snapshot, attempt) : undefined,
      };
    case "approve":
      return canApprove(state) && attempt
        ? {
            ...state,
            approval: {
              runId: state.snapshot.id,
              attemptId: attempt.id,
              cursor: state.snapshot.cursor,
              digests: attempt.artifacts.map((artifact) => artifact.digest),
            },
          }
        : state;
    case "disconnect":
      return { ...state, connection: "disconnected" };
    case "receive": {
      if (action.snapshot.id !== state.snapshot.id || BigInt(action.snapshot.cursor) < BigInt(state.snapshot.cursor))
        return state;
      const changed = action.snapshot.cursor !== state.snapshot.cursor;
      return {
        ...state,
        snapshot: action.snapshot,
        connection: "live",
        selected: action.snapshot.attempts.some((item) => item.id === state.selected)
          ? state.selected
          : (action.snapshot.attempts[0]?.id ?? ""),
        reviewed: changed ? undefined : state.reviewed,
        approval: changed ? undefined : state.approval,
      };
    }
  }
}
