import { AsyncLocalStorage } from "node:async_hooks";

const querySignalStorage = new AsyncLocalStorage<AbortSignal>();

/** Runs database work with a signal that the underlying driver can cancel. */
export function runWithCloudDbQuerySignal<T>(
  signal: AbortSignal | undefined,
  operation: () => T,
): T {
  if (!signal) return operation();
  return querySignalStorage.run(signal, operation);
}

export function currentCloudDbQuerySignal(): AbortSignal | undefined {
  return querySignalStorage.getStore();
}
