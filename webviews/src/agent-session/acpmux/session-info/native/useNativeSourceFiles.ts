import { useEffect, useRef, useState } from "react";
import type { Translate } from "../../i18n";

/// Sources keeps the web row's transient failure feedback, with one bounded timer per failed file.
export function useNativeSourceFiles(open: ((path: string) => unknown) | undefined, t: Translate) {
  const [failures, setFailures] = useState<Readonly<Record<string, string>>>({});
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const live = useRef(false);
  useEffect(() => {
    live.current = true;
    const owned = timers.current;
    return () => {
      live.current = false;
      for (const timer of owned.values()) clearTimeout(timer);
      owned.clear();
    };
  }, []);
  const clear = (path: string) => {
    clearTimeout(timers.current.get(path));
    timers.current.delete(path);
    setFailures((current) => {
      const { [path]: _, ...rest } = current;
      return rest;
    });
  };
  return {
    failures,
    open:
      open &&
      ((path: string) => {
        clear(path);
        return Promise.resolve()
          .then(() => open(path))
          .catch((error: unknown) => {
            if (!live.current) return;
            setFailures((current) => ({
              ...current,
              [path]: error instanceof Error ? error.message : t("changes.openFailed"),
            }));
            timers.current.set(
              path,
              setTimeout(() => clear(path), 4_000),
            );
          });
      }),
  };
}
