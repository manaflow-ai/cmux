// A test's host client fed the host's batches as a page is: through the document's receiver
// (rows/receiver.ts `receiveChatRows`), which routes each change to the store that holds its sid
// and answers `taken` with `post`. The receiver is the document's, so each feed starts it over with
// this one host client in it.
import type { ChatRowsHost, ChatRowsPost } from "../../src/agent-session/acpmux/rows/host";
import { addChatRowsHost, receiveChatRows, resetChatRowsReceiver } from "../../src/agent-session/acpmux/rows/receiver";

/// Hands `host` each batch of change strings, numbered from 1.
export function chatRowsFeed(host: ChatRowsHost, post: ChatRowsPost): (changes: readonly string[]) => void {
  resetChatRowsReceiver();
  addChatRowsHost(host, post);
  let batch = 0;
  return (changes) => receiveChatRows({ batch: ++batch, changes });
}
