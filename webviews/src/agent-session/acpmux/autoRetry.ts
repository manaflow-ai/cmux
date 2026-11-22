// A failure that asking again clears (a re-fetch, a re-list, a re-read, a reconnect, a re-poll) is not
// the person's decision: the page asks again on its own and says nothing, and only a failure that has
// lasted the house deadline gets one quiet line, with no button (Leo, 2026-11-22: "i dont know what kind
// of decision a "try again" would be other than "ok i guess ill click this." vacuous decisions like that
// should be just done and the underlying problems should be done better at the root"). A retry with a
// cost or a side effect the person must choose (a re-sent message, a paid model request, a tool or
// command run again, a sign-in, a destructive action) keeps its button, marked `retry-prompt-ok`.
//
// One loop for every page: `AutoRetryLoop` (plain timers, for stores) and `useAutoRetry` (React).
// While the failure lasts and the view is visible it asks again after a jittered backoff (hostRetry.ts
// `jitteredDelay`, so tabs restored over one dead service do not ask in lockstep), from 1 s up to
// `REFUSED_RETRY_MAX_MS`; a hidden view asks nothing, and asks once at once when it shows again.
import { useEffect, useRef, useState } from "react";
import { useLasting } from "../../ui/lasting";
import { REFUSED_RETRY_MAX_MS, jitteredDelay } from "./hostRetry";

/// The first wait before asking again. Most of these reads failed on a service that was starting or a
/// link that dropped for a moment, which answers within a second or two.
export const AUTO_RETRY_FIRST_MS = 1_000;
/// The longest wait between asks: hostRetry.ts's bound for a refusal that waits on something else, so
/// one that clears by itself is found within 30 s.
export const AUTO_RETRY_MAX_MS = REFUSED_RETRY_MAX_MS;

export type AutoRetryOptions = {
  /// The first wait, before jitter.
  firstMs?: number;
  /// The longest wait, before jitter.
  maxMs?: number;
  /// 0..1; tests pass a fixed one.
  random?: () => number;
  /// Whether the document is visible now; defaults to `document.visibilityState`.
  visible?: () => boolean;
};

function documentVisible(): boolean {
  return typeof document === "undefined" || document.visibilityState !== "hidden";
}

/// The retry schedule for one failing read, with no React: `fail()` after a failed attempt arms the
/// next ask (if none is armed), `succeed()` ends the stretch and resets the backoff, `pause()` holds
/// the asks while an attempt is in flight, `setShown()` follows the view, `wake()` follows the
/// document's visibility, `dispose()` clears the timer. Each ask arms the next one, so the loop keeps
/// asking while the failure lasts even when a retry reports nothing new. While hidden no timer runs; on
/// showing again with a failure outstanding it asks once at once.
export class AutoRetryLoop {
  private timer: ReturnType<typeof setTimeout> | undefined;
  private step: number;
  private failing = false;
  private shown = true;
  private disposed = false;
  private readonly firstMs: number;
  private readonly maxMs: number;
  private readonly random: () => number;
  private readonly visible: () => boolean;

  constructor(
    private readonly ask: () => void,
    options: AutoRetryOptions = {},
  ) {
    this.firstMs = options.firstMs ?? AUTO_RETRY_FIRST_MS;
    this.maxMs = options.maxMs ?? AUTO_RETRY_MAX_MS;
    this.random = options.random ?? Math.random;
    this.visible = options.visible ?? documentVisible;
    this.step = this.firstMs;
  }

  /// Whether a failure is outstanding (from the first `fail` until a `succeed`).
  get isFailing(): boolean {
    return this.failing;
  }

  /// The attempt failed: arm the next ask unless one is already armed.
  fail(): void {
    if (this.disposed) return;
    this.failing = true;
    if (this.timer === undefined) this.arm();
  }

  /// The attempt succeeded (or the read is no longer wanted): stop and reset the backoff.
  succeed(): void {
    this.failing = false;
    this.step = this.firstMs;
    this.clear();
  }

  /// An attempt is in flight: no ask until it ends with `fail` or `succeed`.
  pause(): void {
    this.clear();
  }

  /// The view showed or hid (the component's own shown state).
  setShown(shown: boolean): void {
    if (this.disposed || shown === this.shown) return;
    this.shown = shown;
    this.wake();
  }

  /// The document's visibility changed: a hidden view asks nothing; one visible again with a failure
  /// outstanding asks once at once, then the backoff goes on from where it was.
  wake(): void {
    if (this.disposed) return;
    this.clear();
    if (this.failing && this.live()) this.fire();
  }

  dispose(): void {
    this.disposed = true;
    this.clear();
  }

  private live(): boolean {
    return this.shown && this.visible();
  }

  private arm(): void {
    this.clear();
    if (!this.live()) return;
    const wait = jitteredDelay(this.step, this.random);
    this.timer = setTimeout(() => {
      this.timer = undefined;
      this.fire();
    }, wait);
  }

  private fire(): void {
    if (this.disposed || !this.failing || !this.live()) return;
    // The step doubles per ask, not per arm: a wait cut short (an attempt in flight, a hidden page)
    // does not lengthen the next one.
    this.step = Math.min(this.step * 2, this.maxMs);
    this.arm();
    this.ask();
  }

  private clear(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
  }
}

export type AutoRetryState = {
  /// Whether the failure has lasted the house deadline (lasting.ts `LASTING_MS`, the same 25 s as
  /// hostRetry.ts `HOST_ERROR_DEADLINE_MS`): then, and only then, the page shows one quiet line such as
  /// "Still trying to reach X…", with no button. The gallery's zero grace shows it at once.
  stillTrying: boolean;
};

/// Asks again on its own while `failed` holds and the view is visible (`shown`, default true, and
/// `document.visibilityState`), with jittered backoff; asks once at once when the view shows again.
/// `failed` is the read's failure: anything truthy (an error, a message, `true`) is a failure, and a
/// new truthy value (a fresh error from the retry) arms the next ask. `busy` is an attempt in flight;
/// while it holds no ask starts and the failure stretch goes on, so `stillTrying` counts from the first
/// failure to the first success, not from the latest attempt. `retry` may change identity each render.
export function useAutoRetry(
  failed: unknown,
  retry: () => void,
  { busy = false, shown = true, ...options }: AutoRetryOptions & { busy?: boolean; shown?: boolean } = {},
): AutoRetryState {
  const retryRef = useRef(retry);
  useEffect(() => {
    retryRef.current = retry;
  });
  const loopRef = useRef<AutoRetryLoop | undefined>(undefined);
  const [stretch, setStretch] = useState(false);
  // The options are read once per mount: a page's backoff does not change while it is open.
  const [mountOptions] = useState(options);
  const failing = !!failed;

  useEffect(() => {
    const loop = new AutoRetryLoop(() => retryRef.current(), mountOptions);
    loopRef.current = loop;
    const onVisibility = () => loop.wake();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      loop.dispose();
      loopRef.current = undefined;
    };
  }, [mountOptions]);

  useEffect(() => {
    loopRef.current?.setShown(shown);
  }, [shown]);

  useEffect(() => {
    const loop = loopRef.current;
    if (!loop) return;
    if (busy) {
      loop.pause();
      return;
    }
    if (failing) {
      setStretch(true);
      loop.fail();
    } else {
      setStretch(false);
      loop.succeed();
    }
    // A new failure value (a fresh error from the last ask) arms the next ask.
  }, [failed, failing, busy]);

  return { stillTrying: useLasting(stretch && (failing || busy)) };
}
