// Whether the composer draws Stop: the turn's running state with hysteresis, so Stop never flickers
// when a turn ends and the next starts a few ms later (a queued prompt, a steer, a subagent's notice).
// Leo, 2026-11-22: "we ought to have a better fade in/fade out and maybe a pulse when you for some
// reason start stop quick. so that the composer isn't flickering with the stop button."
//
// The model is Rust's (cmux-tui/crates/cmux-motion/src/turn_presence.rs), copied line for line: the
// page has no Rust in it, so both run the one corpus (cmux-motion/tests/cases/turn_presence.json;
// turnPresence.test.ts here, tests/turn_presence_cases.rs there). Change the Rust and the corpus
// first, then this copy. The rules:
// - a turn shows Stop once it has run DWELL_MS; a shorter one never does. The person's send shows it
//   at once (they caused it and are looking at it);
// - a turn's end keeps Stop LINGER_MS; a turn that starts again inside that window keeps Stop up and
//   counts a pulse (the page draws a short pulse in place of Stop going and coming back);
// - every change of what is drawn stands at least HOLD_MS, shown or gone (a send excepted);
// - the first state, and the state after a chat switch, draws at once.
import { useEffect, useState } from "react";
import { MOTION_MS } from "../../../motion/scale.generated";

/// How long a turn runs before Stop shows (the motion scale's micro step).
export const DWELL_MS = MOTION_MS.micro;
/// The shortest time Stop is drawn, or not drawn, before it may change again.
export const HOLD_MS = 480;
/// How long Stop stays after a turn ends: the hold. A queued prompt or another agent's message
/// opens its turn 50-400 ms after it lands (Leo's 2026-11-22 22:05Z session: 49, 220 and 400 ms).
export const LINGER_MS = HOLD_MS;

export class TurnPresence {
  private runningNow: boolean;
  private runningSince: number;
  private shownNow: boolean;
  private shownSince: number | undefined;
  private immediate = false;
  private pulseCount = 0;

  /// The state at a chat's first draw or a chat switch: drawn as it is.
  constructor(running: boolean, at: number) {
    this.runningNow = running;
    this.runningSince = at;
    this.shownNow = running;
    this.shownSince = undefined;
  }

  get shown(): boolean {
    return this.shownNow;
  }
  get running(): boolean {
    return this.runningNow;
  }
  /// Stop is drawn though no turn runs: the linger after a turn's end.
  get lingering(): boolean {
    return this.shownNow && !this.runningNow;
  }
  /// How many pulses Stop has drawn; the page plays one on each increase.
  get pulses(): number {
    return this.pulseCount;
  }

  /// The running state at `at`. `immediate`: the person's own send started it.
  set(running: boolean, at: number, immediate = false): void {
    if (running !== this.runningNow) {
      if (running && this.shownNow) this.pulseCount += 1;
      this.runningNow = running;
      this.runningSince = at;
      this.immediate = running && immediate;
    } else if (running && immediate) this.immediate = true;
    this.advance(at);
  }

  /// Applies the change due by `at`, if any.
  advance(at: number): void {
    const due = this.due();
    if (due !== undefined && at >= due) {
      this.shownNow = this.runningNow;
      this.shownSince = due;
      this.immediate = false;
    }
  }

  /// When the drawn state changes next with no new input, if it will.
  nextWake(): number | undefined {
    return this.due();
  }

  private heldUntil(): number {
    return this.shownSince === undefined ? 0 : this.shownSince + HOLD_MS;
  }

  private due(): number | undefined {
    if (!this.shownNow && this.runningNow)
      return this.immediate ? this.runningSince : Math.max(this.runningSince + DWELL_MS, this.heldUntil());
    if (this.shownNow && !this.runningNow) return Math.max(this.runningSince + LINGER_MS, this.heldUntil());
    return undefined;
  }
}

const clock = () => globalThis.performance?.now() ?? Date.now();

export type StopPresence = { shown: boolean; lingering: boolean; pulses: number };

/// The composer's Stop presence for `running` in `scope` (the chat). `sentAt`: when the person last
/// sent from this composer (Date.now ms, 0 for never), read when a turn starts; a turn that starts within SEND_MS of it shows Stop
/// at once. One timer, only while a change is due; none at rest.
export function useStopPresence(running: boolean, scope: string | undefined, sentAt?: () => number): StopPresence {
  const [state, setState] = useState(() => ({ scope, model: new TurnPresence(running, clock()), tick: 0 }));
  let { model } = state;
  if (state.scope !== scope) {
    // A chat switch: the chat's state arriving is not a change, so it draws at once.
    model = new TurnPresence(running, clock());
    setState({ scope, model, tick: state.tick + 1 });
  } else if (model.running !== running) {
    const at = clock();
    const sent = running && sentAt ? sentAt() : 0;
    model.set(running, at, sent > 0 && Date.now() - sent <= SEND_MS);
  } else model.advance(clock());
  const wake = model.nextWake();
  useEffect(() => {
    if (wake === undefined) return undefined;
    const timer = setTimeout(
      () => setState((current) => ({ ...current, tick: current.tick + 1 })),
      Math.max(0, wake - clock()),
    );
    return () => clearTimeout(timer);
    // `tick`: a timer that fired a hair early schedules again.
  }, [wake, model, state.tick]);
  return { shown: model.shown, lingering: model.lingering, pulses: model.pulses };
}

/// A turn that starts this soon after the person's send is that send's turn.
export const SEND_MS = 1_000;
