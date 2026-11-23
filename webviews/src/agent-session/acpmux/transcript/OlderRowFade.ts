/// Rows from a page of older history that came late (readerAtLoadedTop) fade on their first mounted copy, including warm copies
/// outside the view. Eligibility is consumed before paint; an intersection only releases the
/// observation and never starts a second fade. Opacity only, so nothing measured moves.
export class OlderRowFade {
  private readonly pending = new Set<string>();
  private readonly waiting = new Map<Element, () => void>();
  private intersections: IntersectionObserver | undefined;
  constructor(private readonly root: () => HTMLElement | null) {}
  add(id: string) {
    this.pending.add(id);
  }
  has(id: string) {
    return this.pending.has(id);
  }
  shown(id: string) {
    this.pending.delete(id);
  }
  clear() {
    this.pending.clear();
  }
  /// Releases the first copy's observation when it intersects; returns the unwatch.
  watch(node: HTMLElement, shown: () => void): () => void {
    if (typeof IntersectionObserver === "undefined") {
      shown();
      return () => {};
    }
    this.intersections ??= new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const target = entry.target as HTMLElement;
          target.dataset.olderShown = "true";
          this.intersections?.unobserve(target);
          this.waiting.get(target)?.();
          this.waiting.delete(target);
        }
      },
      { root: this.root() },
    );
    this.waiting.set(node, shown);
    this.intersections.observe(node);
    return () => {
      this.waiting.delete(node);
      this.intersections?.unobserve(node);
    };
  }
  disconnect() {
    this.intersections?.disconnect();
    this.intersections = undefined;
    this.waiting.clear();
  }
}
