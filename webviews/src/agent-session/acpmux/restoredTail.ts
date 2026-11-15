// The native document resource names the restored tab before the daemon handshake answers.
// This context only selects retained history to paint; connection identity still comes from ready.
import { AcpmuxDirectClient } from "./direct";
import type { AcpmuxSnapshot } from "./model";
import { observeHostTail } from "./tailCache";

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
