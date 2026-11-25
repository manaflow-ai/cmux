// When the pane-edge strip may reveal the rail over the text (Leo, 2026-11-22: "the scroll rail is
// slightly too sensitive to stuff when at small sizes ... there's a lot of awkwardness when you try to
// e.g. copy text along this area"). Prior art: macOS overlay scrollers and VS Code's minimap never
// react to a pointer that is dragging; hover cards (ui/hoverIntent.ts) wait for a rest. So the strip
// reveals the rail only for a pointer that is up and has rested on the strip for REVEAL_DWELL, and a
// press that began anywhere else (a selection drag) keeps it hidden until that press ends, hiding a
// rail already shown. No imports, so the rail and its test read it alike.

/// How long a pointer with no button down rests on the strip before the rail reveals. A sweep past
/// the edge is on it for 30 to 100 ms; a deliberate approach (hover wave, scrub) rests longer.
export const REVEAL_DWELL = 140;

export interface RevealClock {
  set(run: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

const realClock: RevealClock = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export class RailRevealIntent {
  private timer: unknown;
  private onStrip = false;
  private textPress = false;

  constructor(
    private readonly reveal: () => void,
    private readonly hideForPress: () => void,
    private readonly clock: RevealClock = realClock,
    readonly dwell: number = REVEAL_DWELL,
  ) {}

  /// A press began outside the rail (its text, a selection drag): the rail stays out of it.
  get pressingText() {
    return this.textPress;
  }

  /// The pointer is on the strip. `buttons` is the pointer's pressed-button mask: a drag never reveals.
  enter(buttons: number) {
    this.onStrip = true;
    this.arm(buttons);
  }

  /// The pointer moved on the strip: a rest only counts from its last move, and a press that ended
  /// under a still strip hover arms the reveal again.
  move(buttons: number) {
    if (this.onStrip) this.arm(buttons);
  }

  leave() {
    this.onStrip = false;
    this.cancel();
  }

  /// A press anywhere outside the rail, strip and card (the page's capture listener).
  pressOutside() {
    this.textPress = true;
    this.cancel();
    this.hideForPress();
  }

  /// Any press ended or was cancelled.
  release() {
    this.textPress = false;
  }

  cancel() {
    if (this.timer === undefined) return;
    this.clock.clear(this.timer);
    this.timer = undefined;
  }

  private arm(buttons: number) {
    this.cancel();
    if (buttons !== 0 || this.textPress) return;
    this.timer = this.clock.set(() => {
      this.timer = undefined;
      if (this.onStrip && !this.textPress) this.reveal();
    }, this.dwell);
  }
}
