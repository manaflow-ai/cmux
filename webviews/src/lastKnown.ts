// The last answer a picker read, kept for its next open in this page (stale while revalidate):
// the picker draws it at once and reads again behind it, replacing it when the answer arrives.
// Leo, 2026-11-10: "Anything with a stupid loading state ... Anything that is uncached for no
// reason ... It gets fixed." Module memory only, never storage: an agent page lives as long as its
// pane, so a picker that unmounts and opens again finds what it read; nothing outlives the page.

/** Pickers draw their last-known answer on open. False: every open waits for its read as before. */
export const PICKER_LAST_KNOWN = true;

/** A bounded map, least recently used out first. */
export class LastKnown<T> {
  private readonly entries = new Map<string, T>();

  constructor(private readonly limit = 16) {}

  get(key: string): T | undefined {
    if (!PICKER_LAST_KNOWN) return undefined;
    const value = this.entries.get(key);
    if (value === undefined) return undefined;
    // Touch: the key moves to the newest end.
    this.entries.delete(key);
    this.entries.set(key, value);
    return value;
  }

  set(key: string, value: T): void {
    if (!PICKER_LAST_KNOWN) return;
    this.entries.delete(key);
    this.entries.set(key, value);
    while (this.entries.size > this.limit) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }

  delete(key: string): void {
    this.entries.delete(key);
  }

  clear(): void {
    this.entries.clear();
  }

  get size(): number {
    return this.entries.size;
  }
}
