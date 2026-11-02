// What Ctrl-B says (runInBackground.ts): that the work moved, or why nothing did. acpmux's
// `_acpmux/process/background` found nothing in the foreground, acpmux refused the request (another
// harness), acpmux never answered within the request's 10 s (direct.ts `backgroundWork`), or the
// connection to acpmux was down or closed mid-request. Claude Code's SDK reads an answer with no
// `backgrounded` as a move, so a move is checked: a call it named that still runs in the foreground
// a moment later earns "kept" instead of "moved" (Leo, 2026-10-26: "wait idk if that control b thing
// worked"). One short line above the composer, in the pane's notice slot (NoticeSlot.tsx), leaves
// on the next key or click, after a few seconds, with a newer request, or when the chat changes.
import { useCallback, useEffect, useRef, useState } from "react";
import type { StringKey } from "../i18n";

export type BackgroundNotice = "moved" | "kept" | "nothing" | "refused" | "timedOut" | "disconnected";

/// Each notice's line.
export const BACKGROUND_NOTICE_TEXT: Record<BackgroundNotice, StringKey> = {
  moved: "tools.backgroundMoved",
  kept: "tools.backgroundKept",
  nothing: "tools.backgroundNothing",
  refused: "tools.backgroundRefused",
  timedOut: "tools.backgroundTimedOut",
  disconnected: "tools.backgroundDisconnected",
};

/// How long a notice stays when nothing else clears it.
export const BACKGROUND_NOTICE_MS = 6_000;

/// How long after acpmux says the work moved the calls it was asked about may still run in the
/// foreground: Claude Code ends a moved call with its "running in background" result at once.
export const BACKGROUND_CHECK_MS = 2_000;

/// The notice a background request's outcome earns: acpmux's answer, or the request's failure.
/// `{backgrounded: false}` says nothing was there; any other answer is a move. A connection that was not open
/// (`native.not_connected`) or closed mid-request (direct.ts `rejectPending`: `native.timed_out`
/// with reason `interrupted`) is lost; a plain timeout leaves the work running; every other failure
/// is acpmux's refusal.
export function backgroundNotice(outcome: { answer: unknown } | { error: unknown }): BackgroundNotice | undefined {
  if ("answer" in outcome) {
    const answer = outcome.answer as { backgrounded?: unknown } | null | undefined;
    return answer?.backgrounded === false ? "nothing" : "moved";
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
/// connection to ask). `stillForeground`, read `BACKGROUND_CHECK_MS` after a move, says whether a
/// call the request was about still runs in the foreground. Only the newest request of the chat
/// shown when it was sent draws its notice.
export function useBackgroundNotice(sessionId: string | undefined): {
  notice: BackgroundNotice | undefined;
  track(request: Promise<unknown> | undefined, stillForeground?: () => boolean): void;
} {
  const [notice, setNotice] = useState<BackgroundNotice | undefined>();
  const generation = useRef(0);
  const session = useRef(sessionId);
  // The pending move check: one at a time, cleared by a newer request, another chat or unmount.
  const check = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const stopCheck = useCallback(() => {
    clearTimeout(check.current);
    check.current = undefined;
  }, []);
  useEffect(() => {
    session.current = sessionId;
    generation.current += 1;
    stopCheck();
    setNotice(undefined);
  }, [sessionId, stopCheck]);
  useEffect(() => stopCheck, [stopCheck]);
  const track = useCallback((request: Promise<unknown> | undefined, stillForeground?: () => boolean) => {
    const asked = ++generation.current;
    const from = session.current;
    stopCheck();
    setNotice(undefined);
    const current = () => asked === generation.current && from === session.current;
    const settle = (outcome: { answer: unknown } | { error: unknown }) => {
      if (!current()) return;
      const earned = backgroundNotice(outcome);
      setNotice(earned);
      if (earned !== "moved" || !stillForeground) return;
      check.current = setTimeout(() => {
        check.current = undefined;
        if (current() && stillForeground()) setNotice("kept");
      }, BACKGROUND_CHECK_MS);
    };
    (request ?? Promise.reject(Object.assign(new Error(), { code: "native.not_connected" }))).then(
      (answer) => settle({ answer }),
      (error: unknown) => settle({ error }),
    );
  }, [stopCheck]);
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
