// l10n-allow-file: gallery fixtures, not shipped UI.
import type { MoveView, PlaceState } from "./placeModel";

const STARTED = Date.UTC(2026, 9, 6, 9, 41, 0);

const base: MoveView = {
  session: "s-1",
  direction: "toCloud",
  trigger: "person",
  from: "This Mac",
  to: "swift-otter",
  state: "moving",
  step: "sync",
  stepIndex: 2,
  stepCount: 8,
  startedMs: STARTED,
  elapsedMs: 4200,
  budgetMs: 10_000,
  overBudget: false,
  canCancel: true,
  finishing: false,
  runsAt: "local",
  carries: [
    { kind: "history", how: "carried" },
    { kind: "turn", how: "continues" },
    { kind: "branch", how: "carried", name: "lane/cloud-auto" },
    { kind: "changes", how: "carried", count: 3 },
  ],
  interruptsTurn: false,
  canRetry: false,
};

export const MOVES = {
  /// Sync, uncommitted changes, a turn that goes on at Cloud.
  moving: base,
  interrupts: {
    ...base,
    step: "preflight",
    stepIndex: 0,
    elapsedMs: 900,
    carries: [
      { kind: "history", how: "carried" },
      { kind: "turn", how: "interrupted" },
      { kind: "queue", how: "carried", count: 2 },
      { kind: "draft", how: "carried" },
    ],
    interruptsTurn: true,
  },
  overBudget: { ...base, step: "machine", stepIndex: 1, elapsedMs: 13_400, overBudget: true },
  finishing: { ...base, step: "commit", stepIndex: 5, elapsedMs: 8100, canCancel: false, finishing: true },
  failed: {
    ...base,
    state: "failed",
    step: "sync",
    stepIndex: 2,
    elapsedMs: 6800,
    canCancel: false,
    reason: "The folder could not be copied: the Cloud VM ran out of disk space.",
    canRetry: true,
  },
  live: {
    ...base,
    state: "live",
    step: "release",
    stepIndex: 7,
    elapsedMs: 7300,
    canCancel: false,
    runsAt: "cloud",
  },
  auto: {
    ...base,
    trigger: { auto: "sleep" },
    step: "freeze",
    stepIndex: 3,
    elapsedMs: 5200,
  },
} satisfies Record<string, MoveView>;

/// The clock a fixture is drawn at: its start and its elapsed time.
export const at = (move: MoveView): number => move.startedMs + move.elapsedMs;

export const PLACES = {
  local: { mode: "local", at: "local" },
  cloud: { mode: "cloud", at: "cloud", cloudName: "swift-otter" },
  autoLocal: { mode: "auto", at: "local" },
  autoCloud: { mode: "auto", at: "cloud", cloudName: "swift-otter" },
  moving: { mode: "cloud", at: "local", cloudName: "swift-otter", move: MOVES.moving },
} satisfies Record<string, PlaceState>;
