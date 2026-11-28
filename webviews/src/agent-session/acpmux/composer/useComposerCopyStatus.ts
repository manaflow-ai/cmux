import { useCallback, useEffect, useRef, useState } from "react";
import type { ComposerCopyStatus } from "./composerCopy";

/// Copy feedback belongs to the composer that started it. Leaving that chat cancels its bytes;
/// late replies cannot draw feedback in the next chat or in an unmounted composer.
export function useComposerCopyStatus(scope: string | undefined) {
  const owner = useRef(scope);
  owner.current = scope;
  const mounted = useRef(false);
  const active = useRef<ComposerCopyStatus>(undefined);
  const [shown, setShown] = useState<{ scope: string | undefined; status: ComposerCopyStatus }>();
  const update = useCallback(
    (status: ComposerCopyStatus) => {
      if (!mounted.current || owner.current !== scope) return;
      active.current = status;
      setShown((before) => {
        // Chunks may acknowledge faster than the percentage changes. Retain the current cancel
        // operation above, and only render a visible change.
        if (
          before &&
          before.scope === scope &&
          before.status?.phase === "copying" &&
          status?.phase === "copying" &&
          Math.floor((before.status.written / Math.max(1, before.status.total)) * 100) ===
            Math.floor((status.written / Math.max(1, status.total)) * 100)
        )
          return before;
        return { scope, status };
      });
    },
    [scope],
  );
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      const status = active.current;
      active.current = undefined;
      if (status?.phase === "copying") status.cancel();
    };
  }, [scope]);
  return [shown && shown.scope === scope ? shown.status : undefined, update] as const;
}
