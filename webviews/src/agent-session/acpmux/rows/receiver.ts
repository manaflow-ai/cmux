// The document receiver is shared with other page lists; this adapter keeps the chat rows contract.
import type { ChatRowsBatch, ChatRowsHost, ChatRowsPost } from "./host";
import { StorePart } from "./store";
import { changeSid, parseChange } from "./wire";
import { createDocumentPump, type DocumentPumpPost } from "../documentPump";
import type { Lanes } from "../schedule";

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
    if (post) void post("chat.rows.taken", { batch: batch.batch }).catch(() => {});
  },
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
