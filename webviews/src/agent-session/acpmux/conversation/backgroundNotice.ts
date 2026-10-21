// What Ctrl-B says when nothing moved to the background (runInBackground.ts): acpmux's
// `_acpmux/process/background` found nothing in the foreground, the request was refused (another
// harness, a closed connection, no acpmux to ask), or acpmux never answered within the request's
// 10 s (direct.ts `backgroundWork`). One short line above the composer, in the pane's notice slot
// (NoticeSlot.tsx), leaves on the next key or click, after a few seconds, with a newer request, or
// when the chat changes. Work that moved says nothing here: its row leaves the foreground.
import { useCallback, useEffect, useRef, useState } from "react";
import type { StringKey } from "../i18n";

export type BackgroundNotice = "nothing" | "refused" | "timedOut";

/// Each notice's line.
export const BACKGROUND_NOTICE_TEXT: Record<BackgroundNotice, StringKey> = {
  nothing: "tools.backgroundNothing",
  refused: "tools.backgroundRefused",
  timedOut: "tools.backgroundTimedOut",
};

/// How long a notice stays when nothing else clears it.
export const BACKGROUND_NOTICE_MS = 6_000;

/// The notice a background request's outcome earns: acpmux's answer, or the request's failure.
/// Only `{backgrounded: false}` says nothing was there; a timeout (direct.ts `native.timed_out`,
/// also a connection lost mid-request) leaves the work running; every other failure is a refusal.
export function backgroundNotice(outcome: { answer: unknown } | { error: unknown }): BackgroundNotice | undefined {
  if ("answer" in outcome) {
    const answer = outcome.answer as { backgrounded?: unknown } | null | undefined;
    return answer?.backgrounded === false ? "nothing" : undefined;
  }
  const code = (outcome.error as { code?: unknown } | null | undefined)?.code;
  return code === "native.timed_out" ? "timedOut" : "refused";
}

/// The chat's Ctrl-B notice, and `track` to show the one a request earns (`undefined`: no acpmux to
/// ask). Only the newest request of the chat shown when it was sent draws its notice.
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
    (request ?? Promise.reject(new Error())).then(
      (answer) => settle({ answer }),
      (error: unknown) => settle({ error }),
    );
  }, []);
  useEffect(() => {
    if (!notice) return;
    const clear = () => setNotice(undefined);
    const timer = setTimeout(clear, BACKGROUND_NOTICE_MS);
    // ui-allow: the notice leaves on the person's next key or click anywhere in the chat; no src/ui widget watches the page's input.
    window.addEventListener("keydown", clear, true);
    window.addEventListener("pointerdown", clear, true);
    return () => {
      clearTimeout(timer);
      window.removeEventListener("keydown", clear, true);
      window.removeEventListener("pointerdown", clear, true);
    };
  }, [notice]);
  return { notice, track };
}
