// The endpoint harness a form added and has not saved yet (Fetch Models, or an add whose check
// failed or is still running): Settings > Agents > Add > Endpoint and the Chief editor's Bring your
// own share this. The form owns a harness the moment its add answers, before the check. A form
// closed without a passing check removes it, an add that answers after the form closed is removed
// when it answers, and `discard` removes it at once (a change of preset, kind or URL starts over).
// Removes run one after another. The next add's id is known before the click (`useNextTarget`),
// from ids read after the start-over, which still show a harness being removed, so a new add never
// takes a removed id.
import { useEffect, useMemo, useRef, useState } from "react";
import { failureText, newTargetPast, type AddTarget, type EndpointService } from "./byoEndpoint";

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

/** Asks for the remove after every earlier one; `pending` settles when it answered (either way). */
function queueRemove(pending: { current: Promise<void> }, remove: { current: (id: string) => unknown }, id: string) {
  pending.current = pending.current
    .then(() => remove.current(id))
    .then(
      () => {},
      () => {},
    );
}

export function useOwnedEndpoint(remove: (id: string) => unknown): OwnedEndpoint {
  const removeRef = useRef(remove);
  removeRef.current = remove;
  const pending = useRef<Promise<void>>(Promise.resolve());
  const own = useRef<{ id: string | null; saved: boolean; closed: boolean }>({ id: null, saved: false, closed: false });
  useEffect(() => {
    const mine = own.current;
    mine.closed = false;
    return () => {
      mine.closed = true;
      if (mine.id && !mine.saved) queueRemove(pending, removeRef, mine.id);
    };
  }, []);
  return useMemo(
    () => ({
      claim(id: string) {
        own.current.id = id;
        own.current.saved = false;
        if (own.current.closed) queueRemove(pending, removeRef, id);
      },
      discard() {
        const id = own.current.id;
        own.current.id = null;
        if (id && !own.current.saved) queueRemove(pending, removeRef, id);
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

/** The id the form's next new add takes, known before the click: the host's add must run in the
 * click's short gesture window, and reading the harness ids can take seconds. `target` is null
 * until the ids are read (the form keeps Add disabled: it never guesses an id that may be taken),
 * and `failed` says why a read failed. The ids are read once, and again on `refresh()` (a start-over,
 * or an add that left the form owning nothing); the form's own target, when it has one, wins. */
export interface NextTarget {
  target: AddTarget | null;
  failed: string | null;
  refresh(): void;
}

export function useNextTarget(
  service: Pick<EndpointService, "harnessIds">,
  name: string,
  fallback: string,
  target: AddTarget | null,
): NextTarget {
  const [taken, setTaken] = useState<{ ids: string[] } | { failed: string } | null>(null);
  const [round, setRound] = useState(0);
  useEffect(() => {
    let live = true;
    service.harnessIds().then(
      (ids) => live && setTaken({ ids }),
      (failure) => live && setTaken({ failed: failureText(failure) }),
    );
    return () => {
      live = false;
    };
  }, [service, round]);
  return {
    target: target ?? (taken && "ids" in taken ? newTargetPast(name, fallback, taken.ids) : null),
    failed: !target && taken && "failed" in taken ? taken.failed : null,
    refresh: () => {
      setTaken(null);
      setRound((before) => before + 1);
    },
  };
}
