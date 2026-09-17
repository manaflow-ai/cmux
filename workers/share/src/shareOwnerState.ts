export const MAX_ACTIVE_SHARES_PER_OWNER = 5;
export const MAX_SHARE_CREATIONS_PER_MINUTE = 10;
const CREATION_WINDOW_MS = 60_000;

export type OwnerShareRecord = {
  readonly shareId: string;
  readonly expiresAt: number;
};

export type OwnerIndexState = {
  readonly activeShares: readonly OwnerShareRecord[];
  readonly creationTimes: readonly number[];
};

export type OwnerReservationResult =
  | { readonly ok: true; readonly state: OwnerIndexState }
  | {
      readonly ok: false;
      readonly error: "too_many_active_shares" | "create_rate_limited";
      readonly state: OwnerIndexState;
    };

export function reserveOwnerShare(
  current: OwnerIndexState,
  shareId: string,
  expiresAt: number,
  now: number,
): OwnerReservationResult {
  const state = pruneOwnerIndex(current, now);
  if (state.activeShares.some((share) => share.shareId === shareId)) return { ok: true, state };
  if (state.activeShares.length >= MAX_ACTIVE_SHARES_PER_OWNER) {
    return { ok: false, error: "too_many_active_shares", state };
  }
  if (state.creationTimes.length >= MAX_SHARE_CREATIONS_PER_MINUTE) {
    return { ok: false, error: "create_rate_limited", state };
  }
  return {
    ok: true,
    state: {
      activeShares: [...state.activeShares, { shareId, expiresAt }],
      creationTimes: [...state.creationTimes, now],
    },
  };
}

export function pruneOwnerIndex(current: OwnerIndexState, now: number): OwnerIndexState {
  return {
    activeShares: current.activeShares.filter((share) => share.expiresAt > now),
    creationTimes: current.creationTimes.filter((createdAt) => createdAt > now - CREATION_WINDOW_MS),
  };
}

export function emptyOwnerIndex(): OwnerIndexState {
  return { activeShares: [], creationTimes: [] };
}
