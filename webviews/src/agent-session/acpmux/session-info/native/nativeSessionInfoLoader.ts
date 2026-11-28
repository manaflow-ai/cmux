type Module = typeof import("./NativeSessionInfo");

let loaded: Module | undefined;
let loading: Promise<Module> | undefined;
const listeners = new Set<() => void>();

/** Starts loading the App-drawn panel's code once; a failed fetch is tried again on the next call. */
export function loadNativeSessionInfo(): Promise<Module> {
  loading ??= import("./NativeSessionInfo").then(
    (module) => {
      loaded = module;
      for (const listener of listeners) listener();
      return module;
    },
    (error: unknown) => {
      loading = undefined;
      throw error;
    },
  );
  return loading;
}

export function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (!loaded) void loadNativeSessionInfo().catch(() => undefined);
  return () => listeners.delete(listener);
}

export const current = () => loaded;
