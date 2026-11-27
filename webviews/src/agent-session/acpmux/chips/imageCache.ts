// The data URLs reply images loaded from the host (ReplyImage.tsx), so an image scrolled out of
// the virtual transcript and back draws at once. A data URL can be megabytes, so the cache keeps
// the most recently drawn images up to a count and a total length, and forgets the oldest first.

/// About 48 MB of data URL text, or 128 images, whichever comes first.
export const IMAGE_CACHE_MAX_CHARS = 48_000_000;
export const IMAGE_CACHE_MAX_ENTRIES = 128;

export class DataUrlCache {
  private readonly entries = new Map<string, string>();
  private chars = 0;

  constructor(
    private readonly maxEntries = IMAGE_CACHE_MAX_ENTRIES,
    private readonly maxChars = IMAGE_CACHE_MAX_CHARS,
    /// Called with each source the cache forgets to make room.
    private readonly onEvict: (src: string) => void = () => {},
  ) {}

  get size(): number {
    return this.entries.size;
  }

  get totalChars(): number {
    return this.chars;
  }

  /// The data URL for `src`, which becomes the most recently used.
  get(src: string): string | undefined {
    const data = this.entries.get(src);
    if (data === undefined) return undefined;
    this.entries.delete(src);
    this.entries.set(src, data);
    return data;
  }

  set(src: string, data: string): void {
    const before = this.entries.get(src);
    if (before !== undefined) {
      this.entries.delete(src);
      this.chars -= before.length;
    }
    this.entries.set(src, data);
    this.chars += data.length;
    // The newest image always stays, even one longer than the whole budget.
    while (this.entries.size > 1 && (this.entries.size > this.maxEntries || this.chars > this.maxChars)) {
      const [oldest, value] = this.entries.entries().next().value!;
      this.entries.delete(oldest);
      this.chars -= value.length;
      this.onEvict(oldest);
    }
  }
}
