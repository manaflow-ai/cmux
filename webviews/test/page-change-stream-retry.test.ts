// The History and Stashed Tabs page stores follow the owner link before their change stream, so a
// change subscribe that fails at start (the daemon was restarting) is asked for again when the
// link comes back, and the page reads again instead of staying disconnected until a reload.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { PAGE_CONNECTION } from "../src/pages/shared/pageStreams";
import { HistoryStore } from "../src/pages/history/store";
import { StashStore } from "../src/pages/stash/store";
import { HistoryOps } from "../src/pages/history/types";
import { StashOps } from "../src/pages/stash/types";

/** A page client whose change stream refuses its first subscribe; the test drives the link. */
class FlakyClient implements PageClient {
  readonly subscribes: string[] = [];
  readonly calls: string[] = [];
  private connection?: (data: unknown, seq: number) => void;
  constructor(
    private readonly changed: string,
    private readonly answers: Record<string, unknown>,
    private refusals = 1,
  ) {}

  async call<R>(op: string): Promise<R> {
    this.calls.push(op);
    if (!(op in this.answers)) throw Object.assign(new Error(op), { code: "cmux.protocol.unknown_op" });
    return this.answers[op] as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    this.subscribes.push(stream);
    if (stream === PAGE_CONNECTION) this.connection = onEvent as (data: unknown, seq: number) => void;
    if (stream === this.changed && this.refusals > 0) {
      this.refusals -= 1;
      throw Object.assign(new Error("owner restarting"), { name: "PageError", code: "cmux.page.unavailable" });
    }
    return () => {};
  }

  handle(): () => void {
    return () => {};
  }

  link(connected: boolean): void {
    this.connection?.({ connected }, 0);
  }
}

const settle = async () => {
  for (let i = 0; i < 20; i += 1) await Promise.resolve();
};

for (const page of [
  {
    name: "Stashed Tabs",
    changed: StashOps.changed,
    read: StashOps.list,
    answers: { [StashOps.list]: [] },
    make: (client: PageClient) => new StashStore(client),
    // The stash list is the daemon's own: no stream, no read.
    readsWithoutStream: false,
  },
  {
    name: "History",
    changed: HistoryOps.changed,
    read: HistoryOps.list,
    answers: { [HistoryOps.list]: { entries: [] } },
    make: (client: PageClient) => new HistoryStore(client),
    // The list is the app's read model (cmux#37302 review), which answers while the daemon's stream is down.
    readsWithoutStream: true,
  },
]) {
  test(`${page.name}: a change subscribe refused at start is retried on reconnect, then the page reads`, async () => {
    const client = new FlakyClient(page.changed, page.answers);
    const store = page.make(client);
    const stop = store.subscribe(() => {});
    await settle();
    expect(client.subscribes[0]).toBe(PAGE_CONNECTION);
    expect(client.subscribes.filter((s) => s === page.changed)).toHaveLength(1);
    if (page.readsWithoutStream) {
      expect(client.calls.filter((op) => op === page.read)).toHaveLength(1);
      expect(store.getSnapshot().connection).toBe("connected");
    } else {
      expect(store.getSnapshot().connection).toBe("disconnected");
      expect(client.calls).not.toContain(page.read);
    }

    client.link(false);
    client.link(true);
    await settle();
    expect(client.subscribes.filter((s) => s === page.changed)).toHaveLength(2);
    expect(client.calls).toContain(page.read);
    expect(store.getSnapshot().connection).not.toBe("disconnected");
    stop();
  });
}

/** A page client whose first change subscribe stays pending until the test settles it. */
class PendingClient extends FlakyClient {
  private pending?: { resolve: (stop: () => void) => void; reject: (error: unknown) => void };
  readonly stopped: number[] = [];
  private changedStream: string;

  constructor(changed: string, answers: Record<string, unknown>) {
    super(changed, answers, 0);
    this.changedStream = changed;
  }

  override async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== this.changedStream || this.pending || this.subscribes.includes(stream)) {
      return super.subscribe(stream, onEvent);
    }
    this.subscribes.push(stream);
    const index = this.subscribes.length;
    return new Promise((resolve, reject) => {
      this.pending = { resolve: (stop) => resolve(() => (this.stopped.push(index), stop())), reject };
    });
  }

  fail(): void {
    this.pending?.reject(
      Object.assign(new Error("owner restarting"), { name: "PageError", code: "cmux.page.unavailable" }),
    );
  }

  succeed(): void {
    this.pending?.resolve(() => {});
  }
}

for (const page of [
  {
    name: "Stashed Tabs",
    changed: StashOps.changed,
    read: StashOps.list,
    answers: { [StashOps.list]: [] },
    make: (client: PageClient) => new StashStore(client),
  },
  {
    name: "History",
    changed: HistoryOps.changed,
    read: HistoryOps.list,
    answers: { [HistoryOps.list]: { entries: [] } },
    make: (client: PageClient) => new HistoryStore(client),
  },
]) {
  test(`${page.name}: a reconnect while the change subscribe is pending retries once it fails`, async () => {
    const client = new PendingClient(page.changed, page.answers);
    const store = page.make(client);
    const stop = store.subscribe(() => {});
    await settle();
    expect(client.subscribes.filter((s) => s === page.changed)).toHaveLength(1);

    // The link drops and comes back while the first subscribe is still on its way, then it fails.
    client.link(false);
    client.link(true);
    await settle();
    client.fail();
    await settle();

    expect(client.subscribes.filter((s) => s === page.changed)).toHaveLength(2);
    expect(client.calls).toContain(page.read);
    expect(store.getSnapshot().connection).not.toBe("disconnected");
    stop();
  });

  test(`${page.name}: a subscribe from the lost link is dropped and asked for again`, async () => {
    const client = new PendingClient(page.changed, page.answers);
    const store = page.make(client);
    const stop = store.subscribe(() => {});
    await settle();

    client.link(false);
    client.link(true);
    await settle();
    client.succeed();
    await settle();

    // The lost link's stream is stopped, a fresh one is followed, and the page reads.
    expect(client.stopped).toHaveLength(1);
    expect(client.subscribes.filter((s) => s === page.changed)).toHaveLength(2);
    expect(client.calls).toContain(page.read);
    expect(store.getSnapshot().connection).not.toBe("disconnected");
    stop();
  });
}

/** cmux#37302 review: History's entries do not wait on the change stream. The local daemon is down
 * (its stream answers `closed`), and the list (the app's read model) still answers: the page shows
 * the entries, and the stream is asked for again on the next reconnect. */
test("History: a change stream that fails does not keep the entries from the list", async () => {
  const entry = {
    id: "command:build-box/7",
    kind: "command",
    at_ms: 1_000,
    title: "make test",
    available: true,
    machine: "build-box",
  };
  const client = new FlakyClient(HistoryOps.changed, { [HistoryOps.list]: { entries: [entry] } }, 1);
  const store = new HistoryStore(client);
  const stop = store.subscribe(() => {});
  await settle();
  expect(client.calls.filter((op) => op === HistoryOps.list)).toHaveLength(1);
  expect(store.getSnapshot().entries.map((row) => row.id)).toEqual(["command:build-box/7"]);
  expect(store.getSnapshot().connection).toBe("connected");

  client.link(false);
  client.link(true);
  await settle();
  expect(client.subscribes.filter((s) => s === HistoryOps.changed)).toHaveLength(2);
  stop();
});
