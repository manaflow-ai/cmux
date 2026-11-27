// `useDisclosure(key)`: the one open-state hook a transcript row opens and closes by
// (docs/design/transcript-motion-model.md, "The owner, and what a row may no longer do"). It gives
// `open` and `toggle` (and `set`, for a caller that names the state), read from and written to the
// one open-state store (disclosureStore.ts), which the list reads for its state signature and its
// estimate. Each toggle is one transition of the motion owner (motionOwner.ts `transition`, cause
// "disclosure", anchored on the row the disclosure is drawn in), which declares the move to the
// layout watcher (`layoutWatch.expect`). Outside a transcript (a gallery, a card elsewhere) no owner
// is provided and the change applies at once, as before.
//
// Keys:
// - a string: a line of the transcript's choices (transcriptDisclosureModel.ts), with its default,
//   its Verbose default and its links, exactly as `useTranscriptDisclosure` reads them;
// - `{ message, sessionId }`: a message the person opened (incomingOpened.ts);
// - `{ card }`: an edited-files card the reader opened (turnChanges/openStore.ts).

import { useCallback, useContext, useSyncExternalStore } from "react";
import { cardOpen, setCardOpen } from "../turnChanges/openStore";
import { subscribeDisclosure } from "./disclosureStore";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import {
  DisclosureMotion,
  DisclosureRow,
  type DisclosureLinks,
  useTranscriptDisclosure,
} from "./transcriptDisclosureModel";

export type DisclosureKey = string | { message: string; sessionId: string | undefined } | { card: string };

export type DisclosureOptions = {
  defaultOpen?: boolean;
  verboseOpen?: boolean;
  links?: DisclosureLinks;
};

export type Disclosure = {
  open: boolean;
  /// Open a closed one, close an open one: one transition of the motion owner.
  toggle: () => void;
  /// Set it open or closed (nothing when it already is): one transition of the motion owner.
  set: (open: boolean) => void;
};

/// Runs `apply` as one disclosure transition on the row it is drawn in, or at once outside a transcript.
function useRun(): (apply: () => void) => void {
  const run = useContext(DisclosureMotion);
  const rowId = useContext(DisclosureRow);
  return useCallback(
    (apply: () => void) => {
      if (run && rowId !== undefined) run(rowId, apply);
      else apply();
    },
    [run, rowId],
  );
}

/// Runs a change to several disclosures at once (a digest's head opening every message in it) as one
/// disclosure transition on the row it is drawn in.
export const useDisclosureRun = useRun;

const NO_OPTIONS: DisclosureOptions = {};

export function useDisclosure(key: DisclosureKey, options: DisclosureOptions = NO_OPTIONS): Disclosure {
  const isLine = typeof key === "string";
  const line = isLine ? key : "";
  const [lineOpen, setLine] = useTranscriptDisclosure(line, options.defaultOpen, options.verboseOpen, options.links);
  const message = typeof key === "object" && "message" in key ? key : undefined;
  const card = typeof key === "object" && "card" in key ? key.card : undefined;
  const messageSession = message?.sessionId;
  const messageId = message?.message;
  const read = useCallback(
    () =>
      messageId !== undefined ? messageOpened(messageSession, messageId) : card !== undefined ? cardOpen(card) : false,
    [messageSession, messageId, card],
  );
  const spaceOpen = useSyncExternalStore(subscribeDisclosure, read, read);
  const open = isLine ? lineOpen : spaceOpen;
  const run = useRun();
  const set = useCallback(
    (next: boolean) => {
      // A line's setter runs its own transition (transcriptDisclosureModel.ts).
      if (isLine) return setLine(next);
      if (next === read()) return;
      run(() => {
        if (messageId !== undefined) setMessageOpened(messageSession, messageId, next);
        else if (card !== undefined) setCardOpen(card, next);
      });
    },
    [isLine, run, read, messageSession, messageId, card, setLine],
  );
  const toggle = useCallback(() => set(!open), [set, open]);
  return { open, toggle, set };
}
