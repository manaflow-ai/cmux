// A test's host client fed the host's batches as a page is: through the document's receiver
// (rows/receiver.ts `receiveChatRows`), which routes each change to the store that holds its sid
// and answers `taken` with `post`. The receiver is the document's, so each feed starts it over with
// this one host client in it, on lanes that run each batch before `receiveChatRows` returns.
import type { ChatRowsHost, ChatRowsPost } from "../../src/agent-session/acpmux/rows/host";
import { addChatRowsHost, receiveChatRows, resetChatRowsReceiver } from "../../src/agent-session/acpmux/rows/receiver";
import type { Lanes } from "../../src/agent-session/acpmux/schedule";

/// Lanes that run a frame task at once, in the receiving task: for tests and benches about where
/// changes go, not when (rows/receiver.test.ts covers the frame pacing).
export function syncLanes(): Lanes {
  const slice = { timeLeft: () => Number.POSITIVE_INFINITY, shouldYield: () => false };
  return {
    frame: (_key, fn) => void fn(slice),
    idle: (_key, fn) => void fn(slice),
    inputPending: () => false,
    yield: () => Promise.resolve(),
    flush: () => {},
    dispose: () => {},
  };
}

/// Hands `host` each batch of change strings, numbered from 1.
export function chatRowsFeed(host: ChatRowsHost, post: ChatRowsPost): (changes: readonly string[]) => void {
  resetChatRowsReceiver();
  addChatRowsHost(host, post);
  const lanes = syncLanes();
  let batch = 0;
  return (changes) => receiveChatRows({ batch: ++batch, changes }, lanes);
}
