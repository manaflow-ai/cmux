// l10n-allow-file: gallery fixtures, not shipped UI.
import type { EvacuateState, MoveView, PlaceState } from "./placeModel";

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
  /// Settings > Machines' AutoCloud on, Cloud Toggle off: the chat offers AutoCloud off (Local) and on (Auto).
  twoLocal: { mode: "local", at: "local", modes: ["local", "auto"] },
  twoAuto: { mode: "auto", at: "local", modes: ["local", "auto"] },
  twoAutoCloud: { mode: "auto", at: "cloud", cloudName: "swift-otter", modes: ["local", "auto"] },
} satisfies Record<string, PlaceState>;

const EVAC_STARTED = Date.UTC(2026, 9, 6, 9, 41, 0);

export const EVACUATES = {
  /// Five chats: one waiting, two moving at different steps, one in Cloud, one failed.
  running: {
    running: 3,
    done: 1,
    failed: 1,
    total: 5,
    startedMs: EVAC_STARTED,
    elapsedMs: 12_600,
    chats: [
      { session: "e-1", title: "Fix the flaky sync test", state: "live" },
      { session: "e-2", title: "Port the settings page", state: "moving", step: "carry" },
      { session: "e-3", title: "Review the billing PR", state: "moving", step: "sync" },
      { session: "e-4", title: "Draft the release notes", state: "queued" },
      {
        session: "e-5",
        title: "Profile the chat list",
        state: "failed",
        step: "machine",
        reason: "Its Cloud VM could not start: your plan's VM limit is reached.",
      },
    ],
  },
  /// Done: four in Cloud, one failed and can be retried.
  finished: {
    running: 0,
    done: 4,
    failed: 1,
    total: 5,
    startedMs: EVAC_STARTED,
    elapsedMs: 31_400,
    chats: [
      { session: "e-1", title: "Fix the flaky sync test", state: "live" },
      { session: "e-2", title: "Port the settings page", state: "live" },
      { session: "e-3", title: "Review the billing PR", state: "live" },
      { session: "e-4", title: "Draft the release notes", state: "live" },
      {
        session: "e-5",
        title: "Profile the chat list",
        state: "failed",
        step: "machine",
        reason: "Its Cloud VM could not start: your plan's VM limit is reached.",
      },
    ],
  },
  /// Idle, with three chats in Cloud that Bring Back could bring home.
  bringBackIdle: { running: 0, done: 0, failed: 0, total: 0, canBringBack: 3 },
  /// Bringing five back: one on This Mac, two moving, one waiting, one failed.
  bringBackRunning: {
    running: 3,
    done: 1,
    failed: 1,
    total: 5,
    direction: "toLocal",
    startedMs: EVAC_STARTED,
    elapsedMs: 9400,
    canBringBack: 4,
    chats: [
      { session: "e-1", title: "Fix the flaky sync test", state: "live" },
      { session: "e-2", title: "Port the settings page", state: "moving", step: "sync" },
      { session: "e-3", title: "Review the billing PR", state: "moving", step: "attach" },
      { session: "e-4", title: "Draft the release notes", state: "queued" },
      {
        session: "e-5",
        title: "Profile the chat list",
        state: "failed",
        step: "sync",
        reason: "The folder on This Mac could not be written: the disk is full.",
      },
    ],
  },
  bringBackFinished: {
    running: 0,
    done: 4,
    failed: 1,
    total: 5,
    direction: "toLocal",
    startedMs: EVAC_STARTED,
    elapsedMs: 22_800,
    chats: [
      { session: "e-1", title: "Fix the flaky sync test", state: "live" },
      { session: "e-2", title: "Port the settings page", state: "live" },
      { session: "e-3", title: "Review the billing PR", state: "live" },
      { session: "e-4", title: "Draft the release notes", state: "live" },
      {
        session: "e-5",
        title: "Profile the chat list",
        state: "failed",
        step: "sync",
        reason: "The folder on This Mac could not be written: the disk is full.",
      },
    ],
  },
} satisfies Record<string, EvacuateState>;

/// The clock an Evacuate fixture is drawn at.
export const evacuateAt = (state: EvacuateState): number => (state.startedMs ?? 0) + (state.elapsedMs ?? 0);
