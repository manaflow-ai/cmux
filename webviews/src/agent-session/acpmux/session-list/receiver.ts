import { pageLanes, type Lanes, type Slice } from "../schedule";
import { parseSessionListChange, type SessionListBatch, type SessionListChange } from "./store";
import type { SessionListHost, SessionListPost } from "./host";

const hosts = new Set<SessionListHost>();
let takenPost: SessionListPost | undefined;
let documentLanes: Lanes | undefined;
const pending: SessionListBatch[] = [];
let current: { batch: SessionListBatch; next: number; parts: Map<SessionListHost, Set<string>> } | undefined;
let draining = false;
let failed: unknown;
const FRAME_KEY = "session-list";

type SessionListGlobal = { cmuxSessionList?: { receive(event: SessionListBatch): void } };

export function addSessionListHost(host: SessionListHost, post: SessionListPost): void {
  hosts.add(host);
  takenPost = post;
}

export function removeSessionListHost(host: SessionListHost): void {
  hosts.delete(host);
}

export function listenForSessionList(lanes?: Lanes): void {
  if (lanes) documentLanes = lanes;
  const scope = globalThis as SessionListGlobal;
  scope.cmuxSessionList ??= { receive: receiveDocument };
}

export function resetSessionListReceiver(): void {
  const scope = globalThis as SessionListGlobal;
  if (scope.cmuxSessionList?.receive === receiveDocument) delete scope.cmuxSessionList;
  hosts.clear();
  takenPost = undefined;
  documentLanes = undefined;
  pending.length = 0;
  current = undefined;
  draining = false;
  failed = undefined;
}

function receiveDocument(event: SessionListBatch): void {
  receiveSessionList(event);
}

export function receiveSessionList(event: SessionListBatch, lanes: Lanes = documentLanes ?? pageLanes()): void {
  pending.push(event);
  if (draining) return;
  draining = true;
  lanes.frame(FRAME_KEY, (slice) => drain(lanes, slice, 0));
}

function drain(lanes: Lanes, slice: Slice, applied: number): void | Promise<void> {
  for (;;) {
    if (!current) {
      const batch = pending.shift();
      if (!batch) break;
      current = { batch, next: 0, parts: new Map() };
    }
    const { batch, parts } = current;
    while (current.next < batch.changes.length) {
      if (applied > 0 && (slice.shouldYield() || lanes.inputPending()))
        return lanes.yield().then(() => drain(lanes, slice, 0));
      const change = parseSessionListChange(batch.changes[current.next++]);
      applied += 1;
      if (!change) continue;
      try {
        routeChange(change, parts);
      } catch (error) {
        failed ??= error;
      }
    }
    current = undefined;
    for (const [host, sids] of parts)
      for (const sid of sids)
        try {
          host.store.commit(sid);
        } catch (error) {
          failed ??= error;
        }
    try {
      if (takenPost) void takenPost("list.taken", { batch: batch.batch }).catch(() => {});
    } catch (error) {
      failed ??= error;
    }
  }
  draining = false;
  const error = failed;
  failed = undefined;
  if (error) throw error;
}

function routeChange(change: SessionListChange, parts: Map<SessionListHost, Set<string>>): void {
  for (const host of hosts) {
    const touched = host.store.apply(change);
    if (!touched.length) continue;
    let sids = parts.get(host);
    if (!sids) parts.set(host, (sids = new Set()));
    for (const sid of touched) sids.add(sid);
    if (change.sid) return;
  }
}
