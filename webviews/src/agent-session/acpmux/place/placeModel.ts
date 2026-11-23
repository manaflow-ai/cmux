// What the chat's place controls and its move progress read from `pane.tabState`'s `place` (the app
// writes it from cmux-cloud-start-core `moves::place`, serde camelCase). Pure: parsing and wording
// only. The decisions (when a move starts, when Auto moves, what carries) are Rust's.
import type { StringKey } from "../i18n";

export type PlaceMode = "local" | "cloud" | "auto";
export type PlaceAt = "local" | "cloud";
export type MoveDirection = "toCloud" | "toLocal";
export type MoveStateName = "moving" | "live" | "failed" | "cancelled";
export const MOVE_STEPS = ["preflight", "machine", "sync", "freeze", "carry", "commit", "attach", "release"] as const;
export type MoveStep = (typeof MOVE_STEPS)[number];
export type AutoReason = "sleep" | "lowBattery" | "memory" | "disk" | "away" | "longTurn";
export type MoveTrigger = "person" | "evacuate" | { auto: AutoReason };
export type CarryKind = "history" | "turn" | "queue" | "draft" | "branch" | "changes";
export type CarryHow = "carried" | "continues" | "interrupted";

export interface MoveCarry {
  readonly kind: CarryKind;
  readonly how: CarryHow;
  readonly count?: number;
  readonly name?: string;
}

export interface MoveView {
  readonly session: string;
  readonly direction: MoveDirection;
  readonly trigger: MoveTrigger;
  readonly from: string;
  readonly to: string;
  readonly state: MoveStateName;
  readonly step: MoveStep;
  readonly stepIndex: number;
  readonly stepCount: number;
  readonly startedMs: number;
  readonly elapsedMs: number;
  readonly budgetMs: number;
  readonly overBudget: boolean;
  readonly canCancel: boolean;
  readonly finishing: boolean;
  readonly runsAt: PlaceAt;
  readonly carries: readonly MoveCarry[];
  readonly interruptsTurn: boolean;
  readonly reason?: string;
  readonly canRetry: boolean;
}

export interface PlaceState {
  readonly mode: PlaceMode;
  readonly at: PlaceAt;
  readonly cloudName?: string;
  readonly move?: MoveView;
}

export type EvacuateChatState = "queued" | "moving" | "live" | "failed" | "cancelled";

/// One chat of a running Evacuate: it moves to its own Cloud VM, up to a few at once.
export interface EvacuateChat {
  readonly session: string;
  readonly title: string;
  readonly state: EvacuateChatState;
  readonly step?: MoveStep;
  readonly reason?: string;
}

/// The session list's Evacuate: the counts, and (when the app sends them) one entry per chat and the
/// clock. `chats` is optional: counts alone still draw the summary and the bar.
export interface EvacuateState {
  readonly running: number;
  readonly done: number;
  readonly failed: number;
  readonly total: number;
  readonly chats?: readonly EvacuateChat[];
  /// Which way the chats move; `toLocal` is Bring Back to This Mac. Default `toCloud`.
  readonly direction?: MoveDirection;
  /// How many chats Bring Back could bring home now (the app counts); none hides the button.
  readonly canBringBack?: number;
  readonly startedMs?: number;
  readonly elapsedMs?: number;
}

const MODES: readonly PlaceMode[] = ["local", "cloud", "auto"];
const AUTO_REASONS: readonly AutoReason[] = ["sleep", "lowBattery", "memory", "disk", "away", "longTurn"];
const CARRY_KINDS: readonly CarryKind[] = ["history", "turn", "queue", "draft", "branch", "changes"];
const CARRY_HOWS: readonly CarryHow[] = ["carried", "continues", "interrupted"];
const STATES: readonly MoveStateName[] = ["moving", "live", "failed", "cancelled"];

const num = (value: unknown, fallback: number): number =>
  typeof value === "number" && Number.isFinite(value) ? value : fallback;
const text = (value: unknown): string => (typeof value === "string" ? value : "");

function triggerOf(value: unknown): MoveTrigger {
  if (value === "evacuate") return "evacuate";
  const auto = (value as { auto?: unknown } | null)?.auto;
  if (typeof auto === "string" && (AUTO_REASONS as readonly string[]).includes(auto))
    return { auto: auto as AutoReason };
  return "person";
}

function carriesOf(value: unknown): MoveCarry[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry: unknown): MoveCarry[] => {
    const raw = (entry ?? {}) as Record<string, unknown>;
    if (!(CARRY_KINDS as readonly unknown[]).includes(raw.kind)) return [];
    const how = (CARRY_HOWS as readonly unknown[]).includes(raw.how) ? (raw.how as CarryHow) : "carried";
    return [
      {
        kind: raw.kind as CarryKind,
        how,
        ...(typeof raw.count === "number" ? { count: raw.count } : {}),
        ...(typeof raw.name === "string" && raw.name ? { name: raw.name } : {}),
      },
    ];
  });
}

/// The move the app reports, or none when the value is not one (a half-written push draws nothing).
export function moveOf(value: unknown): MoveView | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  const step = (MOVE_STEPS as readonly unknown[]).includes(raw.step) ? (raw.step as MoveStep) : undefined;
  const state = (STATES as readonly unknown[]).includes(raw.state) ? (raw.state as MoveStateName) : undefined;
  if (!step || !state) return undefined;
  const direction: MoveDirection = raw.direction === "toLocal" ? "toLocal" : "toCloud";
  const carries = carriesOf(raw.carries);
  return {
    session: text(raw.session),
    direction,
    trigger: triggerOf(raw.trigger),
    from: text(raw.from),
    to: text(raw.to),
    state,
    step,
    stepIndex: num(raw.stepIndex, MOVE_STEPS.indexOf(step)),
    stepCount: num(raw.stepCount, MOVE_STEPS.length),
    // The app's `startedMs` is its monotonic clock (uptime), not wall time, so `Date.now() - startedMs`
    // is meaningless here. Its `elapsedMs` is current when it sends: the page ticks from arrival.
    startedMs: Date.now() - num(raw.elapsedMs, 0),
    elapsedMs: num(raw.elapsedMs, 0),
    budgetMs: num(raw.budgetMs, 10_000),
    overBudget: raw.overBudget === true,
    canCancel: raw.canCancel === true,
    finishing: raw.finishing === true,
    runsAt: raw.runsAt === "cloud" ? "cloud" : "local",
    carries,
    interruptsTurn: raw.interruptsTurn === true || carries.some((carry) => carry.how === "interrupted"),
    ...(typeof raw.reason === "string" && raw.reason ? { reason: raw.reason } : {}),
    canRetry: raw.canRetry === true,
  };
}

/// `tabState.place`, or none when the app sends none (a chat the moves do not cover).
export function placeOf(value: unknown): PlaceState | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  if (!(MODES as readonly unknown[]).includes(raw.mode)) return undefined;
  const move = moveOf(raw.move);
  return {
    mode: raw.mode as PlaceMode,
    at: raw.at === "cloud" ? "cloud" : "local",
    ...(typeof raw.cloudName === "string" && raw.cloudName ? { cloudName: raw.cloudName } : {}),
    ...(move ? { move } : {}),
  };
}

const CHAT_STATES: readonly EvacuateChatState[] = ["queued", "moving", "live", "failed", "cancelled"];

function evacuateChatsOf(value: unknown): EvacuateChat[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.flatMap((entry: unknown): EvacuateChat[] => {
    const raw = (entry ?? {}) as Record<string, unknown>;
    if (!(CHAT_STATES as readonly unknown[]).includes(raw.state)) return [];
    const step = (MOVE_STEPS as readonly unknown[]).includes(raw.step) ? (raw.step as MoveStep) : undefined;
    return [
      {
        session: text(raw.session),
        title: text(raw.title),
        state: raw.state as EvacuateChatState,
        ...(step ? { step } : {}),
        ...(typeof raw.reason === "string" && raw.reason ? { reason: raw.reason } : {}),
      },
    ];
  });
}

export function evacuateOf(value: unknown): EvacuateState | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  const chats = evacuateChatsOf(raw.chats);
  return {
    running: num(raw.running, 0),
    done: num(raw.done, 0),
    failed: num(raw.failed, 0),
    total: num(raw.total, 0),
    ...(chats ? { chats } : {}),
    ...(raw.direction === "toLocal" ? { direction: "toLocal" as const } : {}),
    ...(typeof raw.canBringBack === "number" && Number.isFinite(raw.canBringBack) && raw.canBringBack > 0
      ? { canBringBack: Math.floor(raw.canBringBack) }
      : {}),
    // `startedMs` is rebased as in `moveOf`: the app's value is its monotonic clock, so it is ignored.
    startedMs: Date.now() - num(raw.elapsedMs, 0),
    elapsedMs: num(raw.elapsedMs, 0),
  };
}

/// The Evacuate's counts: from `chats` when the app sent them (waiting and moving are both still to
/// do), else the app's own numbers.
export function evacuateCounts(state: EvacuateState): { running: number; done: number; failed: number; total: number } {
  const { chats } = state;
  if (!chats) return { running: state.running, done: state.done, failed: state.failed, total: state.total };
  const count = (...names: EvacuateChatState[]) => chats.filter((chat) => names.includes(chat.state)).length;
  return { running: count("queued", "moving"), done: count("live"), failed: count("failed"), total: chats.length };
}

/// Nothing to draw but the idle button: no Evacuate has run, or it left no chats.
export function evacuateIdle(state: EvacuateState | undefined): boolean {
  return !state || evacuateCounts(state).total === 0;
}

export function evacuateRunning(state: EvacuateState | undefined): boolean {
  return !!state && evacuateCounts(state).running > 0;
}

/// The chats that failed, for Retry.
export function failedSessions(state: EvacuateState): string[] {
  return (state.chats ?? []).filter((chat) => chat.state === "failed" && chat.session).map((chat) => chat.session);
}

/// One mark per chat for the segmented bar; counts alone give done, then moving, then failed, then waiting.
export function evacuateSegments(state: EvacuateState): EvacuateChatState[] {
  if (state.chats) return state.chats.map((chat) => chat.state);
  const { running, done, failed, total } = evacuateCounts(state);
  const waiting = Math.max(0, total - done - failed - running);
  return [
    ...Array<EvacuateChatState>(done).fill("live"),
    ...Array<EvacuateChatState>(failed).fill("failed"),
    ...Array<EvacuateChatState>(running).fill("moving"),
    ...Array<EvacuateChatState>(waiting).fill("queued"),
  ];
}

/// The Evacuate's clock now: ticks from `startedMs` while chats move, the app's `elapsedMs` after.
export function evacuateElapsed(state: EvacuateState, nowMs: number): number {
  const base = state.elapsedMs ?? 0;
  if (!evacuateRunning(state) || state.startedMs === undefined) return base;
  return Math.max(base, nowMs - state.startedMs, 0);
}

/// The step's label key: the machine step reads differently going to this Mac.
export function stepKey(step: MoveStep, direction: MoveDirection): StringKey {
  if (step === "machine" && direction === "toLocal") return "place.step.machineLocal";
  return `place.step.${step}` as StringKey;
}

export function triggerKey(trigger: MoveTrigger): StringKey | undefined {
  if (trigger === "person") return undefined;
  if (trigger === "evacuate") return "place.trigger.evacuate";
  return `place.trigger.${trigger.auto}` as StringKey;
}

/// The move's clock now: ticks from `startedMs` while it runs, the app's `elapsedMs` once it ended.
export function elapsedNow(move: MoveView, nowMs: number): number {
  if (move.state !== "moving") return move.elapsedMs;
  return Math.max(move.elapsedMs, nowMs - move.startedMs, 0);
}

/// "4.2": seconds with one decimal under 10 s, whole seconds above.
export function seconds(ms: number): string {
  const value = Math.max(0, ms) / 1000;
  return value < 10 ? value.toFixed(1) : String(Math.round(value));
}

/// The carries as the card lists them, in the order the app sent. A turn that interrupts is listed
/// first so it is read before the freeze.
export function orderedCarries(move: MoveView): MoveCarry[] {
  const turn = move.carries.filter((carry) => carry.kind === "turn");
  return [...turn, ...move.carries.filter((carry) => carry.kind !== "turn")];
}

/// Which looks of the card draw which part is a design question; what is true is not: Cancel only
/// while `canCancel`, Retry only on a failure.
export function moveActions(move: MoveView): { cancel: boolean; retry: boolean; finishing: boolean } {
  return {
    cancel: move.state === "moving" && move.canCancel && !move.finishing,
    retry: move.state === "failed" && move.canRetry,
    finishing: move.state === "moving" && move.finishing,
  };
}

/// Where the chat runs, named: the move's own words for the old and new place, else the mode's.
export function runsAtName(move: MoveView): string {
  const toCloud = move.direction === "toCloud";
  const [cloudName, localName] = toCloud ? [move.to, move.from] : [move.from, move.to];
  return move.runsAt === "cloud" ? cloudName : localName;
}

/// The Rust gate: a failure at or after `attach` leaves the chat at the new place.
export function landedOnFailure(move: MoveView): boolean {
  return move.state === "failed" && move.runsAt === (move.direction === "toCloud" ? "cloud" : "local");
}

/// How many chats Bring Back to This Mac offers: the app's count, else (after an Evacuate to Cloud)
/// the chats that arrived.
export function bringBackCount(state: EvacuateState | undefined): number {
  if (!state) return 0;
  if (state.canBringBack !== undefined) return state.canBringBack;
  return state.direction === "toLocal" ? 0 : evacuateCounts(state).done;
}
