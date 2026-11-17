// The pricing card's Subscribe (CloudStartView): `cloud.plan.subscribe { plan }` has the host open the plan's
// checkout in the browser (`{ opened: true }`). Back from the browser, the page becomes the key one again
// (pageKey.ts, as githubRepos.ts waits for GitHub) and the plan is read again (`cloudMachine.list`); once it
// admits the held start (`ready`), the start goes again by itself, once. Otherwise the card stays as it is and
// the next return reads again. No timers, no polls.
import { useSyncExternalStore } from "react";
import { currentCloudPlan, refreshCloudMachines } from "./cloudMachines";
import type { CloudPlanId, CloudPlanView } from "./cloudPlans";
import { translate } from "./i18n";
import { postNative } from "./native";
import { pageIsKey, watchPageKey } from "./pageKey";
import { errorMessage } from "./transportErrors";

export type CloudPlanSubscribeState = {
  /// The plan whose Subscribe is with the host: the card's buttons wait.
  pending?: CloudPlanId;
  /// The checkout opened: the page reads the plan again each time it becomes the key one.
  waiting: boolean;
  /// `cloud.plan.subscribe` was refused: the host's words, under the card's buttons.
  error?: string;
};

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

const INITIAL: CloudPlanSubscribeState = { waiting: false };

export function createCloudPlanSubscribe({
  call = postNative,
  watchKey = watchPageKey,
  isKey = pageIsKey,
  readPlan = () => refreshCloudMachines().then(currentCloudPlan),
  onReady = () => undefined,
}: {
  call?: Call;
  watchKey?: (run: () => void) => () => void;
  isKey?: () => boolean;
  /// Reads the plan again (the app's `cloudMachine.list`).
  readPlan?: () => Promise<CloudPlanView>;
  /// The plan now admits the held start: it goes again (App's retry), once.
  onReady?: () => void;
} = {}) {
  let state = INITIAL;
  const listeners = new Set<() => void>();
  let unwatch: (() => void) | undefined;
  /// What the held start needs of the plan; undefined once it went, or after a reset.
  let wanted: ((plan: CloudPlanView) => boolean) | undefined;
  /// Each read's turn: an answer to an older read than the latest, or one after a reset, changes nothing.
  let turn = 0;
  const set = (next: Partial<CloudPlanSubscribeState>) => {
    state = { ...state, ...next };
    for (const listener of listeners) listener();
  };
  const stopWaiting = () => {
    unwatch?.();
    unwatch = undefined;
  };
  const check = () => {
    const asked = ++turn;
    readPlan().then(
      (plan) => {
        if (asked !== turn || !wanted?.(plan)) return;
        wanted = undefined;
        stopWaiting();
        set({ waiting: false });
        onReady();
      },
      () => undefined,
    );
  };
  return {
    snapshot: () => state,
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    /// Subscribe to `plan`; `ready` says whether a plan read later admits the held start.
    start(plan: CloudPlanId, ready: (plan: CloudPlanView) => boolean) {
      if (state.pending) return;
      set({ pending: plan, error: undefined });
      const asked = turn;
      call("cloud.plan.subscribe", { plan }).then(
        () => {
          if (asked !== turn) return;
          wanted = ready;
          set({ pending: undefined, waiting: true });
          unwatch ??= watchKey(() => {
            if (isKey()) check();
          });
        },
        (error: unknown) => {
          if (asked !== turn) return;
          set({
            pending: undefined,
            error: errorMessage(error).trim() || translate("cloudStart.plans.subscribeFailed"),
          });
        },
      );
    },
    /// The card went (Not now, Run on This Mac, another chat): nothing waits any more.
    reset() {
      turn += 1;
      wanted = undefined;
      stopWaiting();
      if (state !== INITIAL) {
        state = INITIAL;
        for (const listener of listeners) listener();
      }
    },
  };
}

export type CloudPlanSubscribeStore = ReturnType<typeof createCloudPlanSubscribe>;

let pageStore: CloudPlanSubscribeStore | undefined;

/// The page's store for a card App passes none to (it retries nothing by itself).
function pageCloudPlanSubscribe(): CloudPlanSubscribeStore {
  if (!pageStore) pageStore = createCloudPlanSubscribe();
  return pageStore;
}

export function useCloudPlanSubscribe(store?: CloudPlanSubscribeStore) {
  const subscriber = store ?? pageCloudPlanSubscribe();
  const state = useSyncExternalStore(subscriber.subscribe, subscriber.snapshot, subscriber.snapshot);
  return { state, start: subscriber.start };
}
