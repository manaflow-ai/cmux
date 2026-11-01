import { describe, expect, test } from "bun:test";
import { AppsStore } from "../src/pages/apps/store";
import { MockAppsProvider } from "../src/pages/apps/mockProvider";
import { AppsOps } from "../src/pages/apps/types";
import { CodeRouterStore } from "../src/pages/coderouter/store";
import { MockCodeRouterProvider } from "../src/pages/coderouter/mockProvider";
import { HistoryStore } from "../src/pages/history/store";
import { MockHistoryProvider } from "../src/pages/history/mockProvider";
import { HistoryOps } from "../src/pages/history/types";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import { PAGE_CONNECTION } from "../src/pages/shared/pageStreams";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

/** Delays the host's subscribe reply, including events delivered before the reply. */
class DelayedClient implements PageClient {
  readonly subscriptions: Array<{
    stream: string;
    emit: (data: unknown) => void;
    stops: number;
    stopped: Promise<void>;
  }> = [];
  readonly calls: string[] = [];
  readonly gates: Array<{
    stream: string;
    entered: ReturnType<typeof deferred<void>>;
    reply: ReturnType<typeof deferred<void>>;
  }> = [];
  unknownWatch = false;

  constructor(private readonly provider: PageClient) {}

  hold(stream: string) {
    const gate = { stream, entered: deferred<void>(), reply: deferred<void>() };
    this.gates.push(gate);
    return gate;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (this.unknownWatch && stream !== PAGE_CONNECTION) throw pageError("cmux.protocol.unknown_op", stream);
    const cleanup = deferred<void>();
    const record = {
      stream,
      emit: (data: unknown) => onEvent(data as E, 1),
      stops: 0,
      stopped: cleanup.promise,
    };
    this.subscriptions.push(record);
    const index = this.gates.findIndex((gate) => gate.stream === stream);
    if (index !== -1) {
      const [gate] = this.gates.splice(index, 1);
      gate!.entered.resolve();
      await gate!.reply.promise;
    }
    return () => {
      record.stops++;
      cleanup.resolve();
    };
  }

  call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push(op);
    return this.provider.call<R>(op, params);
  }

  handle(): () => void {
    return () => undefined;
  }
}

const cases = [
  {
    name: "History",
    make: (client: PageClient) => new HistoryStore(client),
    provider: () => new MockHistoryProvider(),
    watch: HistoryOps.changed,
  },
  {
    name: "Apps",
    make: (client: PageClient) => new AppsStore(client),
    provider: () => new MockAppsProvider(),
    watch: AppsOps.watch,
  },
  {
    name: "CodeRouter",
    make: (client: PageClient) => new CodeRouterStore(client),
    provider: () => new MockCodeRouterProvider(),
    watch: undefined,
  },
];

for (const fixture of cases) {
  describe(`${fixture.name} subscription lifetime`, () => {
    for (const stream of fixture.watch ? [fixture.watch, PAGE_CONNECTION] : [PAGE_CONNECTION]) {
      test(`stop disposes a late ${stream} reply without reloading`, async () => {
        const client = new DelayedClient(fixture.provider());
        const gate = client.hold(stream);
        const store = fixture.make(client);
        const start = store.start();
        await gate.entered.promise;
        store.stop();
        const snapshot = store.getSnapshot();
        // An early event may arrive before subscribe() hands back its cleanup function.
        for (const sub of client.subscriptions) sub.emit({ connected: false });
        expect(store.getSnapshot()).toBe(snapshot);
        expect(client.calls).toEqual([]);
        gate.reply.resolve();
        await start;
        expect(client.subscriptions.every((sub) => sub.stops === 1)).toBe(true);
        expect(client.calls).toEqual([]);
        expect(store.getSnapshot()).toBe(snapshot);
      });

      test(`an obsolete ${stream} failure cannot change a restarted store`, async () => {
        const client = new DelayedClient(fixture.provider());
        const gate = client.hold(stream);
        const store = fixture.make(client);
        const old = store.start();
        await gate.entered.promise;
        store.stop();
        await store.start();
        const snapshot = store.getSnapshot();
        const calls = [...client.calls];
        gate.reply.reject(new Error("old subscribe failed"));
        await old;
        expect(store.getSnapshot()).toBe(snapshot);
        expect(client.calls).toEqual(calls);
        store.stop();
      });

      for (const olderFirst of [true, false]) {
        test(`${stream} restart keeps the new subscription (${olderFirst ? "old" : "new"} reply first)`, async () => {
          const client = new DelayedClient(fixture.provider());
          const gate = client.hold(stream);
          const store = fixture.make(client);
          const old = store.start();
          await gate.entered.promise;
          store.stop();
          const oldRecords = [...client.subscriptions];
          const nextGate = client.hold(stream);
          const next = store.start();
          await nextGate.entered.promise;
          if (olderFirst) {
            gate.reply.resolve();
            await old;
            // Old finally must not clear the replacement's in-flight start marker.
            const count = client.subscriptions.length;
            const duplicate = store.start();
            expect(client.subscriptions).toHaveLength(count);
            nextGate.reply.resolve();
            await Promise.all([next, duplicate]);
          } else {
            nextGate.reply.resolve();
            await next;
            const snapshot = store.getSnapshot();
            const calls = [...client.calls];
            gate.reply.resolve();
            await old;
            expect(store.getSnapshot()).toBe(snapshot);
            expect(client.calls).toEqual(calls);
          }
          const current = client.subscriptions.filter((sub) => !oldRecords.includes(sub));
          expect(oldRecords.every((sub) => sub.stops === 1)).toBe(true);
          expect(current.every((sub) => sub.stops === 0)).toBe(true);
          expect(store.getSnapshot().connection).toBe("connected");
          current.find((sub) => sub.stream === PAGE_CONNECTION)!.emit({ connected: false });
          expect(store.getSnapshot().connection).toBe("disconnected");
          const stopped = store.getSnapshot();
          for (const sub of oldRecords) sub.emit({ connected: true });
          expect(store.getSnapshot()).toBe(stopped);
          store.stop();
          expect(current.every((sub) => sub.stops === 1)).toBe(true);
        });
      }
    }

    test("last listener leaving cancels a pending page subscription", async () => {
      const client = new DelayedClient(fixture.provider());
      const gate = client.hold(PAGE_CONNECTION);
      const store = fixture.make(client);
      const unsubscribe = store.subscribe(() => undefined);
      await gate.entered.promise;
      unsubscribe();
      const snapshot = store.getSnapshot();
      gate.reply.resolve();
      await Promise.all(client.subscriptions.map((sub) => sub.stopped));
      expect(client.subscriptions.every((sub) => sub.stops === 1)).toBe(true);
      expect(client.calls).toEqual([]);
      expect(store.getSnapshot()).toBe(snapshot);
    });

    test("a reload reply after stop does not publish into the stopped store", async () => {
      const client = new DelayedClient(fixture.provider());
      const entered = deferred<void>();
      const reply = deferred<void>();
      const call = client.call.bind(client);
      client.call = async <R>(op: string, params: unknown): Promise<R> => {
        const result = await call<R>(op, params);
        entered.resolve();
        await reply.promise;
        return result;
      };
      const store = fixture.make(client);
      const start = store.start();
      await entered.promise;
      store.stop();
      const snapshot = store.getSnapshot();
      reply.resolve();
      await start;
      expect(store.getSnapshot()).toBe(snapshot);
    });

    if (fixture.watch) {
      test("an unsupported watch still keeps page-stream startup idempotent", async () => {
        const client = new DelayedClient(fixture.provider());
        client.unknownWatch = true;
        const gate = client.hold(PAGE_CONNECTION);
        const store = fixture.make(client);
        const start = store.start();
        await gate.entered.promise;
        await store.start();
        expect(client.subscriptions).toHaveLength(1);
        gate.reply.resolve();
        await start;
        expect(store.getSnapshot().connection).toBe("connected");
        store.stop();
        expect(client.subscriptions[0]!.stops).toBe(1);
      });
    }
  });
}
