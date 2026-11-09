// The endpoint harness a form added and has not saved yet (Fetch Models, or an add whose check
// failed or is still running): Settings > Agents > Add > Endpoint and the Chief editor's Bring your
// own share this. The form owns a harness the moment its add answers, before the check. A form
// closed without a passing check removes it, an add that answers after the form closed is removed
// when it answers, and `discard` removes it at once (a change of preset, kind or URL starts over).
import { useEffect, useMemo, useRef } from "react";

export interface OwnedEndpoint {
  /** An add answered with `id`: owned from now on (removed now if the form already closed). */
  claim(id: string): void;
  /** Starts over: the owned harness is removed and nothing is owned. */
  discard(): void;
  /** The check passed: the harness stays when the form closes. */
  keep(): void;
  /** Whether the form has closed (unmounted). */
  readonly closed: boolean;
}

export function useOwnedEndpoint(remove: (id: string) => void): OwnedEndpoint {
  const removeRef = useRef(remove);
  removeRef.current = remove;
  const own = useRef<{ id: string | null; saved: boolean; closed: boolean }>({ id: null, saved: false, closed: false });
  useEffect(() => {
    const mine = own.current;
    mine.closed = false;
    return () => {
      mine.closed = true;
      if (mine.id && !mine.saved) removeRef.current(mine.id);
    };
  }, []);
  return useMemo(
    () => ({
      claim(id: string) {
        own.current.id = id;
        own.current.saved = false;
        if (own.current.closed) removeRef.current(id);
      },
      discard() {
        const id = own.current.id;
        own.current.id = null;
        if (id && !own.current.saved) removeRef.current(id);
      },
      keep() {
        own.current.saved = true;
      },
      get closed() {
        return own.current.closed;
      },
    }),
    [],
  );
}
