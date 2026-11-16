// The session-list document receiver uses the shared frame-paced pump from B0.
import type { Lanes } from "../schedule";
import { createDocumentPump, type DocumentPumpPost } from "../documentPump";
import type { SessionListHost, SessionListPost } from "./host";
import { parseSessionListChange, type SessionListBatch, type SessionListChange } from "./store";

const pump = createDocumentPump<SessionListBatch, SessionListChange, SessionListHost, Set<string>>({
  frameKey: "session-list",
  globalKey: "cmuxSessionList",
  parse: parseSessionListChange,
  route: (change, hosts, parts) => {
    const stores = new Set<SessionListHost["store"]>();
    for (const host of hosts) {
      if (stores.has(host.store)) continue;
      stores.add(host.store);
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
const visibilityHosts = new Set<SessionListHost>();
let stopVisibility: (() => void) | undefined;

export function addSessionListHost(host: SessionListHost, post: SessionListPost): void {
  const first = visibilityHosts.size === 0;
  pump.add(host, post);
  visibilityHosts.add(host);
  if (first && typeof document !== "undefined") void host.visible(!document.hidden);
}

export function removeSessionListHost(host: SessionListHost): void {
  pump.remove(host);
  visibilityHosts.delete(host);
}

export function listenForSessionList(lanes?: Lanes): void {
  pump.listen(lanes);
  if (stopVisibility || typeof document === "undefined") return;
  const onVisibility = () => {
    for (const host of visibilityHosts) void host.visible(!document.hidden);
  };
  document.addEventListener("visibilitychange", onVisibility);
  stopVisibility = () => document.removeEventListener("visibilitychange", onVisibility);
}

export function resetSessionListReceiver(): void {
  pump.reset();
  visibilityHosts.clear();
  stopVisibility?.();
  stopVisibility = undefined;
}

export function receiveSessionList(event: SessionListBatch, lanes?: Lanes): void {
  pump.receive(event, lanes);
}
