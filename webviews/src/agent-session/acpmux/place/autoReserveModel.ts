// Auto's setting and its last move (RFD 0072, piece 6). The verdict is Rust's (cmux-host-budget); this is
// what the page reads to draw the setting (`cloud.auto`, `cloud.autoReserve`) and the last move.

/// `cloud.autoReserve`'s four stops: the share of this Mac kept for the person (0 to 75%).
export const RESERVE_STOPS = [0, 0.25, 0.5, 0.75] as const;
export const DEFAULT_RESERVE = 0.5;

/// From this share of the pooled Cloud hours the Auto control shows it (RFD 0072, "The ceiling").
export const POOL_NOTICE = 0.8;

/// Why Auto moved a chat out. Each is one short phrase ("Mac was busy"), never a dialog.
export type MoveReason = "cpu" | "memory" | "heat";

export type LastMoveState = "moving" | "moved";

/// The last move Auto made: the chat, why, when. `moving` offers Cancel; `moved` offers Bring Back.
export interface LastMove {
  readonly title: string;
  readonly reason: MoveReason;
  readonly atMs: number;
  readonly state: LastMoveState;
}

export interface AutoReserveState {
  readonly on: boolean;
  /// One of `RESERVE_STOPS`.
  readonly keep: number;
  readonly lastMove?: LastMove;
  /// The share of the pooled Cloud hours used this month, 0 to 1 (the app sends it when it knows).
  readonly pool?: number;
}

export type PoolLevel = "ok" | "near" | "ceiling";

export function poolLevel(pool: number | undefined): PoolLevel {
  if (pool === undefined || !Number.isFinite(pool) || pool < POOL_NOTICE) return "ok";
  return pool >= 1 ? "ceiling" : "near";
}

/// A keep off the stops snaps down to one, as the Rust setting does.
export function snapReserve(value: unknown): number {
  const asked = typeof value === "number" && Number.isFinite(value) ? value : DEFAULT_RESERVE;
  return [...RESERVE_STOPS].reverse().find((stop) => stop <= asked + 1e-9) ?? 0;
}
