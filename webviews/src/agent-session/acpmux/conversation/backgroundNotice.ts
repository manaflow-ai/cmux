// What Ctrl-B says when nothing moved to the background (runInBackground.ts): acpmux's
// `_acpmux/process/background` found nothing in the foreground, acpmux refused the request (another
// harness), acpmux never answered within the request's 10 s (direct.ts `backgroundWork`), or the
// connection to acpmux was down or closed mid-request. One short line above the composer, in the pane's notice slot
// (NoticeSlot.tsx), leaves on the next key or click, after a few seconds, with a newer request, or
// when the chat changes. Work that moved says nothing here: its row leaves the foreground.
import { useCallback, useEffect, useRef, useState } from "react";
import type { StringKey } from "../i18n";

export type BackgroundNotice = "nothing" | "refused" | "timedOut" | "disconnected";

/// Each notice's line.
export const BACKGROUND_NOTICE_TEXT: Record<BackgroundNotice, StringKey> = {
  nothing: "tools.backgroundNothing",
  refused: "tools.backgroundRefused",
  timedOut: "tools.backgroundTimedOut",
  disconnected: "tools.backgroundDisconnected",
};

/// How long a notice stays when nothing else clears it.
export const BACKGROUND_NOTICE_MS = 6_000;

/// The notice a background request's outcome earns: acpmux's answer, or the request's failure.
/// Only `{backgrounded: false}` says nothing was there. A connection that was not open
/// (`native.not_connected`) or closed mid-request (direct.ts `rejectPending`: `native.timed_out`
/// with reason `interrupted`) is lost; a plain timeout leaves the work running; every other failure
/// is acpmux's refusal.
export function backgroundNotice(outcome: { answer: unknown } | { error: unknown }): BackgroundNotice | undefined {
  if ("answer" in outcome) {
    const answer = outcome.answer as { backgrounded?: unknown } | null | undefined;
    return answer?.backgrounded === false ? "nothing" : undefined;
  }
  const error = outcome.error as { code?: unknown; reason?: unknown } | null | undefined;
  if (error?.code === "native.not_connected" || error?.reason === "interrupted") return "disconnected";
  return error?.code === "native.timed_out" ? "timedOut" : "refused";
}

/// A key that clears the notice: a new press, not a held key's repeat or a modifier alone.
function clearsNotice(event: KeyboardEvent): boolean {
  return !event.repeat && !["Control", "Meta", "Alt", "Shift"].includes(event.key);
}

/// The chat's Ctrl-B notice, and `track` to show the one a request earns (`undefined`: no
/// connection to ask). Only the newest request of the chat shown when it was sent draws its notice.
export function useBackgroundNotice(sessionId: string | undefined): {
  notice: BackgroundNotice | undefined;
  track(request: Promise<unknown> | undefined): void;
} {
  const [notice, setNotice] = useState<BackgroundNotice | undefined>();
  const generation = useRef(0);
  const session = useRef(sessionId);
  useEffect(() => {
    session.current = sessionId;
    generation.current += 1;
    setNotice(undefined);
  }, [sessionId]);
  const track = useCallback((request: Promise<unknown> | undefined) => {
    const asked = ++generation.current;
    const from = session.current;
    setNotice(undefined);
    const settle = (outcome: { answer: unknown } | { error: unknown }) => {
      if (asked !== generation.current || from !== session.current) return;
      setNotice(backgroundNotice(outcome));
    };
    (request ?? Promise.reject(Object.assign(new Error(), { code: "native.not_connected" }))).then(
      (answer) => settle({ answer }),
      (error: unknown) => settle({ error }),
    );
  }, []);
  useEffect(() => {
    if (!notice) return;
    const clear = () => setNotice(undefined);
    const onKey = (event: KeyboardEvent) => {
      if (clearsNotice(event)) clear();
    };
    const timer = setTimeout(clear, BACKGROUND_NOTICE_MS);
    // ui-allow: the notice leaves on the person's next key or click anywhere in the chat; no src/ui widget watches the page's input.
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("pointerdown", clear, true);
    return () => {
      clearTimeout(timer);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("pointerdown", clear, true);
    };
  }, [notice]);
  return { notice, track };
}
