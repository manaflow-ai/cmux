// The rows that arrived live and have not mounted yet: each enters (its fade or rise) on its first
// mount, but only if that mount comes soon after it arrived. A row that arrived while the reader was
// scrolled away (outside the virtual window) mounts when the reader scrolls back, maybe minutes
// later: that row is history by then and draws in place, as the load fade's rows do (shared/loadFade.ts
// LOAD_FADE_MOUNT_MS). Kept forever, its entrance played on the scroll back (Leo, 2026-11-21: "i
// srolled up and then bac k down and it replayed an animation"; design/chat-animation-ordering-map.md
// O16, O17).

/// How soon after it arrived a row must mount to enter. A live row mounts in the commit that brings
/// it, or a frame or two later under load; a scroll back takes far longer than this.
export const ENTRANCE_MOUNT_MS = 500; // motion-allow: an arrival-to-mount bound, not an animation

/// Past this many pending entries, expired ones are dropped on the next add: the set stays bounded
/// however long the reader stays away while rows stream in.
const PRUNE_AT = 64;

export class PendingEntrances {
  readonly #arrived = new Map<string, number>();
  readonly #now: () => number;

  constructor(now: () => number = () => performance.now()) {
    this.#now = now;
  }

  /// Row `key` arrived live now.
  add(key: string): void {
    const now = this.#now();
    this.#arrived.delete(key);
    this.#arrived.set(key, now);
    if (this.#arrived.size <= PRUNE_AT) return;
    // Oldest first (insertion order): stop at the first one still in its window.
    for (const [old, at] of this.#arrived) {
      if (now - at <= ENTRANCE_MOUNT_MS) break;
      this.#arrived.delete(old);
    }
  }

  /// Whether row `key` enters if it mounts now.
  has(key: string): boolean {
    const at = this.#arrived.get(key);
    return at !== undefined && this.#now() - at <= ENTRANCE_MOUNT_MS;
  }

  /// Row `key` mounted (it entered, or drew in place): a later mount draws it whole.
  delete(key: string): void {
    this.#arrived.delete(key);
  }

  clear(): void {
    this.#arrived.clear();
  }

  get size(): number {
    return this.#arrived.size;
  }
}
