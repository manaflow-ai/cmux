// Tells the host about unsaved edits (the R96 quit hook: the host marks the document unsaved on the
// first edit and keeps a crash-recovery draft). The first edit is reported at once; edits inside
// the following window are coalesced into one trailing report, so typing does not send the whole
// text on every key.
export const EDIT_REPORT_INTERVAL_MS = 500;

export type EditSchedule = (run: () => void, delayMs: number) => () => void;

/** A file page's answer to the host's `cmux.<page>.viewState` before it discards the page: `view`
 * comes back in the next page's config `viewState`; `dirty` says the page holds edits not on disk,
 * so the host keeps it. */
export interface PageViewStateAnswer {
  dirty: boolean;
  view: unknown;
}

export interface EditReporter {
  /** An edit happened; `send` runs now or at the end of the current window. */
  edited(): void;
  /** A coalesced edit is sent now (the host asks before it discards the page); none sends nothing. */
  flush(): void;
  dispose(): void;
}

export function createEditReporter(send: () => void, schedule: EditSchedule): EditReporter {
  let cancel: (() => void) | null = null;
  let pending = false;
  const open = () => {
    cancel = schedule(() => {
      cancel = null;
      if (!pending) return;
      pending = false;
      send();
      open();
    }, EDIT_REPORT_INTERVAL_MS);
  };
  return {
    edited() {
      if (cancel) {
        pending = true;
        return;
      }
      send();
      open();
    },
    flush() {
      if (!pending) return;
      pending = false;
      send();
    },
    dispose() {
      cancel?.();
      cancel = null;
      pending = false;
    },
  };
}
