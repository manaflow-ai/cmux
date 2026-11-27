// The document receiver is shared with other page lists; this adapter keeps the chat rows contract.
import type { ChatRowsBatch, ChatRowsHost, ChatRowsPost } from "./host";
import { StorePart } from "./store";
import { changeSid, parseChange } from "./wire";
import { createDocumentPump, type DocumentPumpPost } from "../documentPump";
import type { Lanes } from "../schedule";

/// A `taken` whose post failed goes again after each of `delays` (ms), so one dropped bridge call
/// does not leave the host waiting out its own deadline (AcpmuxChatRowsHost.ackWait). Tests replace
/// `schedule`.
export const chatRowsTakenRetry = {
  delays: [100, 500, 2000] as readonly number[],
  schedule: (run: () => void, ms: number): void => void setTimeout(run, ms),
};

function postTaken(post: DocumentPumpPost, batch: number, attempt = 0): void {
  void post("chat.rows.taken", { batch }).catch(() => {
    const delay = chatRowsTakenRetry.delays[attempt];
    if (delay !== undefined) chatRowsTakenRetry.schedule(() => postTaken(post, batch, attempt + 1), delay);
  });
}

const pump = createDocumentPump<ChatRowsBatch, NonNullable<ReturnType<typeof parseChange>>, ChatRowsHost, StorePart>({
  frameKey: "chat-rows",
  globalKey: "cmuxChatRows",
  parse: (value) => (typeof value === "string" ? parseChange(value) : null),
  makePart: () => new StorePart(),
  route: (change, hosts, parts) => {
    const sid = changeSid(change);
    if (sid === null) return;
    for (const host of hosts)
      if (host.store.has(sid)) {
        let part = parts.get(host);
        if (!part) parts.set(host, (part = new StorePart()));
        host.store.applyPart(part, [change]);
        return;
      }
  },
  commit: (host, part) => host.store.commit(part),
  take: (post: DocumentPumpPost | undefined, batch) => {
    if (post) postTaken(post, batch.batch);
  },
  // The host sends an untaken batch again under its number: applied once, taken again.
  key: (batch) => batch.batch,
});

export function addChatRowsHost(host: ChatRowsHost, post: ChatRowsPost): void {
  pump.add(host, post);
}

export function removeChatRowsHost(host: ChatRowsHost): void {
  pump.remove(host);
}

export function listenForChatRows(lanes?: Lanes): void {
  pump.listen(lanes);
}

export function resetChatRowsReceiver(): void {
  pump.reset();
}

export function receiveChatRows(event: ChatRowsBatch, lanes?: Lanes): void {
  pump.receive(event, lanes);
}
