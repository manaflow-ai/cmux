import { pageLanes, type Lanes, type Slice } from "./schedule";

export type DocumentPumpPost = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export type DocumentPumpOptions<Batch, Change, Host, Part> = {
  frameKey: string;
  globalKey: string;
  parse(value: unknown): Change | null;
  route(change: Change, hosts: ReadonlySet<Host>, parts: Map<Host, Part>): void;
  commit(host: Host, part: Part): void;
  take(post: DocumentPumpPost | undefined, batch: Batch): void;
};

/** The document-owned queue and frame-paced drain shared by page list consumers. */
export function createDocumentPump<Batch, Change, Host, Part>(options: DocumentPumpOptions<Batch, Change, Host, Part>) {
  const hosts = new Set<Host>();
  let takenPost: DocumentPumpPost | undefined;
  let documentLanes: Lanes | undefined;
  const pending: Batch[] = [];
  let current: { batch: Batch; changes: readonly unknown[]; next: number; parts: Map<Host, Part> } | undefined;
  let draining = false;
  let failed: { error: unknown } | undefined;

  type Global = Record<string, { receive(event: Batch): void } | undefined>;
  const receiveDocument = (event: Batch): void => receive(event);

  function add(host: Host, post: DocumentPumpPost): void {
    hosts.add(host);
    takenPost = post;
  }

  function remove(host: Host): void {
    hosts.delete(host);
  }

  function listen(lanes?: Lanes): void {
    if (lanes) documentLanes = lanes;
    const scope = globalThis as unknown as Global;
    scope[options.globalKey] ??= { receive: receiveDocument };
  }

  function reset(): void {
    const scope = globalThis as unknown as Global;
    if (scope[options.globalKey]?.receive === receiveDocument) delete scope[options.globalKey];
    hosts.clear();
    takenPost = undefined;
    documentLanes = undefined;
    pending.length = 0;
    current = undefined;
    draining = false;
    failed = undefined;
  }

  function receive(event: Batch, lanes: Lanes = documentLanes ?? pageLanes()): void {
    pending.push(event);
    if (draining) return;
    draining = true;
    lanes.frame(options.frameKey, (slice) => drain(lanes, slice, 0));
  }

  // perf-hot: 4ms chat-rows-frame-apply
  // The drain owns frame pacing and yields before applying more input. Receivers must commit
  // their parts before answering `taken`, so the daemon never advances past a batch the document
  // has not applied. A malformed line is skipped and still taken by the same contract.
  function drain(lanes: Lanes, slice: Slice, applied: number): void | Promise<void> {
    for (;;) {
      if (!current) {
        const batch = pending.shift();
        if (!batch) break;
        const changes = (batch as { changes?: readonly unknown[] }).changes ?? [];
        current = { batch, changes, next: 0, parts: new Map() };
      }
      const { batch, changes, parts } = current;
      while (current.next < changes.length) {
        if (applied > 0 && (slice.shouldYield() || lanes.inputPending()))
          return lanes.yield().then(() => drain(lanes, slice, 0));
        const line = changes[current.next++];
        applied += 1;
        try {
          const change = options.parse(line);
          if (change) options.route(change, hosts, parts);
        } catch (error) {
          failed ??= { error };
        }
      }
      current = undefined;
      for (const [host, part] of parts)
        try {
          options.commit(host, part);
        } catch (error) {
          failed ??= { error };
        }
      try {
        options.take(takenPost, batch);
      } catch (error) {
        failed ??= { error };
      }
    }
    draining = false;
    const error = failed;
    failed = undefined;
    if (error) throw error.error;
  }

  return { add, remove, listen, reset, receive };
}
