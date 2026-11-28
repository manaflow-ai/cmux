// A file whose upload failed is asked again on its own, for as long as its chip is there: its chip
// keeps loading and offers no Retry (Leo, 2026-11-22: "i dont know what kind of decision a "try
// again" would be other than "ok i guess ill click this." vacuous decisions like that should be just
// done"). The same for a staged image's original that was not saved and a chip the host makes
// (attachLater, a dictation recording). Before, each try again waited for the person's next key or
// click, at most twice and 15 s each, and then the chip showed Retry: the host started an upload only
// on a fresh gesture. It no longer asks for one (#45429, Leo 2026-11-17: "go remove this"), so the
// root of that wait is gone and a timer asks again (autoRetry.ts: jittered backoff, 1 s doubling to
// 30 s, nothing while the pane is hidden, once at once when it shows). A failure that lasts the house
// deadline (lasting.ts) gets one quiet "Still trying to upload…" on its tile, never a button; its x
// takes it out.
import { AutoRetryLoop, type AutoRetryOptions } from "../autoRetry";

/// The asks again for a set of chips, by id, with no React. `ask(id)` starts one attempt and answers
/// true, or answers false when it cannot now (its chat is not the one shown): the next ask is then
/// already due. While an attempt runs no other starts; `failed(id)` after it failed arms the next,
/// `end(id)` after it succeeded (or the chip went) stops them.
export class ChipRetries {
  private readonly loops = new Map<string, AutoRetryLoop>();
  private readonly running = new Set<string>();

  constructor(
    private readonly ask: (id: string) => boolean,
    private readonly options: AutoRetryOptions = {},
  ) {}

  /// Whether chip `id` is being asked again (from its first failure until `end`).
  has(id: string): boolean {
    return this.loops.has(id);
  }

  /// Chip `id`'s attempt failed: ask again after the backoff.
  failed(id: string): void {
    this.running.delete(id);
    let loop = this.loops.get(id);
    if (!loop) {
      const made: AutoRetryLoop = new AutoRetryLoop(() => {
        // An attempt still running: no second one beside it; its own end arms the next.
        if (this.running.has(id)) return made.pause();
        if (!this.ask(id)) return;
        this.running.add(id);
        made.pause();
      }, this.options);
      loop = made;
      this.loops.set(id, loop);
    }
    loop.fail();
  }

  /// Chip `id` is made, or gone: no more asks.
  end(id: string): void {
    this.running.delete(id);
    this.loops.get(id)?.dispose();
    this.loops.delete(id);
  }

  /// The pane showed again, or its chat changed: each failing chip asks at once (one with an attempt
  /// running waits for it).
  wake(): void {
    for (const loop of this.loops.values()) loop.wake();
  }

  dispose(): void {
    for (const loop of this.loops.values()) loop.dispose();
    this.loops.clear();
    this.running.clear();
  }
}
