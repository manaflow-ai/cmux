// Each tab slot's resting omnibar (Chromium `OmniboxView::SaveStateToTab`): the toolbar page keeps
// one state per `tab` and puts it back when the pane shows that tab again. Least recently used
// slots go first past the cap, so memory stays bounded however many tabs come and go.
import type { OmnibarState } from "../omnibox/state";

export const TAB_SLOT_LIMIT = 256;

export class TabSlotStore {
  private readonly slots = new Map<string, OmnibarState>();

  constructor(private readonly limit = TAB_SLOT_LIMIT) {}

  get size(): number {
    return this.slots.size;
  }

  /** The slot's state, now the most recently used; undefined for a slot never stored. */
  get(tab: string): OmnibarState | undefined {
    const state = this.slots.get(tab);
    if (state === undefined) return undefined;
    this.slots.delete(tab);
    this.slots.set(tab, state);
    return state;
  }

  set(tab: string, state: OmnibarState): void {
    this.slots.delete(tab);
    this.slots.set(tab, state);
    while (this.slots.size > this.limit) {
      const oldest = this.slots.keys().next().value;
      if (oldest === undefined) break;
      this.slots.delete(oldest);
    }
  }

  delete(tab: string): void {
    this.slots.delete(tab);
  }

  has(tab: string): boolean {
    return this.slots.has(tab);
  }
}
