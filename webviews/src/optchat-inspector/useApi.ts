import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { ApiStore, type Entry } from "./store";

export const StoreContext = createContext<ApiStore>(new ApiStore());

/** The API answer at `url` (null: nothing to load), refreshed every `every` ms while mounted. */
export function useApi<T>(url: string | null, every?: number): Entry<T> {
  const store = useContext(StoreContext);
  const subscribe = useCallback(
    (listener: () => void) => (url ? store.subscribe(url, listener, every) : () => {}),
    [store, url, every],
  );
  const snapshot = useCallback(() => (url ? store.get<T>(url) : IDLE), [store, url]);
  return useSyncExternalStore(subscribe, snapshot, snapshot) as Entry<T>;
}

const IDLE: Entry<never> = { loading: false };
