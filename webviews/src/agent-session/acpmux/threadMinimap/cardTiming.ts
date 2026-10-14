// When the minimap's preview card shows (the Codex app's tooltip timing): it opens
// CARD_OPEN_DELAY_MS after the pointer reaches the rail, at once when one closed less than
// CARD_WARM_MS before or the keyboard focused a row, and closes CARD_CLOSE_DELAY_MS after the
// pointer leaves the rail and the card. It appears and disappears on one frame.
import { CARD_CLOSE_DELAY_MS, CARD_OPEN_DELAY_MS, CARD_WARM_MS } from "./model";

export class CardTiming {
  private opening: ReturnType<typeof setTimeout> | undefined;
  private closing: ReturnType<typeof setTimeout> | undefined;
  private closedAt = -Infinity;
  private shown = false;

  constructor(private readonly show: (open: boolean) => void) {}

  get open(): boolean {
    return this.shown;
  }

  /// The pointer reached the rail or the card.
  enter(): void {
    clearTimeout(this.closing);
    this.closing = undefined;
    if (this.shown || this.opening !== undefined) return;
    if (performance.now() - this.closedAt < CARD_WARM_MS) this.set(true);
    else
      this.opening = setTimeout(() => {
        this.opening = undefined;
        this.set(true);
      }, CARD_OPEN_DELAY_MS);
  }

  /// The pointer left the rail and the card.
  leave(): void {
    clearTimeout(this.opening);
    this.opening = undefined;
    if (!this.shown || this.closing !== undefined) return;
    this.closing = setTimeout(() => {
      this.closing = undefined;
      this.set(false);
    }, CARD_CLOSE_DELAY_MS);
  }

  /// Keyboard focus: the card shows on this frame.
  now(): void {
    this.cancel();
    this.set(true);
  }

  /// Escape, or focus leaving: the card goes on this frame.
  close(): void {
    this.cancel();
    this.set(false);
  }

  cancel(): void {
    clearTimeout(this.opening);
    clearTimeout(this.closing);
    this.opening = this.closing = undefined;
  }

  private set(open: boolean): void {
    if (open === this.shown) return;
    this.shown = open;
    if (!open) this.closedAt = performance.now();
    this.show(open);
  }
}
