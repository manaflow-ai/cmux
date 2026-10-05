// React bindings for IntentStore. Plain hooks over `useSyncExternalStore`, so a store change from
// an input handler renders synchronously in the same event (React flushes external-store updates
// from discrete events before the next paint). The React Compiler memoizes the callers; nothing
// here mutates during render.
import { useSyncExternalStore } from "react";
import type { IntentKind, IntentMeta, IntentStore } from "./store";

type ParamsOf<K> = K extends IntentKind<any, infer P, any> ? P : never;

/**
 * The store's visible state, or a slice of it. `select` must return a value from the state (or a
 * primitive), not a new object per call, or every render sees a change.
 */
export function useIntentState<S, T = S>(store: IntentStore<S, any>, select?: (state: S) => T): T {
  const read = select ? () => select(store.getState()) : (store.getState as unknown as () => T);
  return useSyncExternalStore(store.subscribe, read, read);
}

/** The queue view (pending intents, refusals, loading), derived; stable until it changes. */
export function useIntentMeta(store: IntentStore<any, any>): IntentMeta {
  return useSyncExternalStore(store.subscribe, store.getMeta, store.getMeta);
}

/** A dispatcher for one intent kind. Returns the opid. */
export function useIntent<S, K extends Record<string, IntentKind<S, any, any>>, N extends keyof K & string>(
  store: IntentStore<S, K>,
  kind: N,
): (params: ParamsOf<K[N]>) => string {
  return (params) => store.dispatch(kind, params);
}
