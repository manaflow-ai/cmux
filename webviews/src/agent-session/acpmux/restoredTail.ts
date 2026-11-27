// The native document resource names the restored tab before the daemon handshake answers.
// This context only selects retained history to paint; connection identity still comes from ready.
import { AcpmuxDirectClient } from "./direct";
import type { AcpmuxSnapshot } from "./model";
import { observeHostTail, readHostTail } from "./tailCache";

const RESTORED_CHAT = "__cmuxRestoredChat";
const RESTORED_EVENT = "cmux-restored-chat";

export function watchRestoredTail(draw: (snapshot: AcpmuxSnapshot) => void): () => void {
  let stopRead: (() => void) | undefined;
  let requested = false;
  const read = () => {
    const session = (window as unknown as Record<string, unknown>)[RESTORED_CHAT];
    if (requested || typeof session !== "string" || !session) return;
    requested = true;
    stopRead = observeHostTail(session, (tail) => {
      const snapshot = AcpmuxDirectClient.retainedSnapshot(session, tail);
      if (snapshot?.rows.length) draw(snapshot);
    });
  };
  window.addEventListener(RESTORED_EVENT, read);
  read();
  return () => {
    stopRead?.();
    window.removeEventListener(RESTORED_EVENT, read);
  };
}

/// The restored chat's kept tail, read before the page's first React render (mountModel.tsx), so that
/// render already draws the chat's rows under the copy, not an empty transcript that the tail redraws
/// once the effect's read answers (first-load-after-restart.bench.ts). The first App takes it.
let primed: AcpmuxSnapshot | undefined;

/// Reads the restored chat's tail now, at most `boundMs`: a host slower than that renders without it,
/// and `watchRestoredTail` draws it when it answers, as before. Resolves at once with no restored chat.
export function primeRestoredTail(boundMs: number): Promise<void> {
  const session = (window as unknown as Record<string, unknown>)[RESTORED_CHAT];
  if (typeof session !== "string" || !session) return Promise.resolve();
  // An answer past the bound is the effect's to draw: a page already rendered takes no primed tail.
  let open = true;
  return Promise.race([
    readHostTail(session).then((tail) => {
      if (!open) return;
      const snapshot = tail ? AcpmuxDirectClient.retainedSnapshot(session, tail) : undefined;
      if (snapshot?.rows.length) primed = snapshot;
    }),
    new Promise<void>((resolve) => setTimeout(resolve, boundMs)),
  ])
    .catch(() => undefined)
    .finally(() => {
      open = false;
    });
}

/// The primed tail's snapshot, once.
export function takePrimedRestoredTail(): AcpmuxSnapshot | undefined {
  const taken = primed;
  primed = undefined;
  return taken;
}
