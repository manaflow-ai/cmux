// The session-list document receiver uses the shared frame-paced pump from B0.
import type { Lanes } from "../schedule";
import { createDocumentPump, type DocumentPumpPost } from "../documentPump";
import type { SessionListHost, SessionListPost } from "./host";
import { parseSessionListChange, type SessionListBatch, type SessionListChange } from "./store";

const pump = createDocumentPump<SessionListBatch, SessionListChange, SessionListHost, Set<string>>({
  frameKey: "session-list",
  globalKey: "cmuxSessionList",
  parse: parseSessionListChange,
  makePart: () => new Set<string>(),
  route: (change, hosts, parts) => {
    for (const host of hosts) {
      const touched = host.store.apply(change);
      if (!touched.length) continue;
      let sids = parts.get(host);
      if (!sids) parts.set(host, (sids = new Set()));
      for (const sid of touched) sids.add(sid);
      if (change.sid) return;
    }
  },
  commit: (host, sids) => {
    for (const sid of sids) host.store.commit(sid);
  },
  take: (post: DocumentPumpPost | undefined, batch) => {
    if (post) void post("list.taken", { batch: batch.batch }).catch(() => {});
  },
});

export function addSessionListHost(host: SessionListHost, post: SessionListPost): void {
  pump.add(host, post);
}

export function removeSessionListHost(host: SessionListHost): void {
  pump.remove(host);
}

export function listenForSessionList(lanes?: Lanes): void {
  pump.listen(lanes);
}

export function resetSessionListReceiver(): void {
  pump.reset();
}

export function receiveSessionList(event: SessionListBatch, lanes?: Lanes): void {
  pump.receive(event, lanes);
}
