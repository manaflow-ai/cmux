import { describe, expect, test } from "bun:test";
import { pageError, type PageClient } from "../shared/pageClient";
import { DetailReader, type MachineDetail, type PortAction } from "./detail";
import { ACTION_RUN, CloudOps, HostActions, type BrowserRoute, type PortForward } from "./ops";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

const forward = (machine = "a", port = 3000): PortForward => ({
  machine,
  port,
  host: "127.0.0.1",
  localPort: port + 10000,
  generation: 1,
  state: "up",
});
const route = (machine = "a", port = 3000): BrowserRoute => ({
  machine,
  url: `http://localhost:${port}`,
  incarnation: 1,
  generation: 1,
  proxy: { kind: "http", host: "127.0.0.1", port: 9000, username: "sample", password: "sample" },
});

async function fixture() {
  let detail: MachineDetail | undefined;
  let key = 0;
  let changeable = true;
  const failures: unknown[] = [];
  const unavailable: string[] = [];
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  type Held = ReturnType<typeof deferred<unknown>> & {
    started: Promise<Record<string, unknown>>;
    entered: (params: Record<string, unknown>) => void;
  };
  const held = new Map<string, Held[]>();
  function hold(op: string): Held {
    const answer = deferred<unknown>();
    const started = deferred<Record<string, unknown>>();
    const item = { ...answer, started: started.promise, entered: started.resolve };
    const queue = held.get(op) ?? [];
    queue.push(item);
    held.set(op, queue);
    return item;
  }
  const client: PageClient = {
    async call<R>(op: string, args: unknown): Promise<R> {
      const params = args as Record<string, unknown>;
      calls.push({ op, params });
      const waiting = held.get(op)?.shift();
      if (waiting) {
        waiting.entered(params);
        return (await waiting.promise) as R;
      }
      if (op === CloudOps.snapshotList) return { snapshots: [] } as R;
      if (op === CloudOps.portList) return { forwards: [forward(String(params.machine))] } as R;
      if (op === CloudOps.portForward) return forward(String(params.machine), Number(params.port)) as R;
      if (op === CloudOps.browserOpen) return route(String(params.machine), Number(params.port)) as R;
      return null as R;
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  };
  const reader = new DetailReader(client, {
    get: () => detail,
    set: (next) => {
      detail = next;
    },
    fail: (error) => {
      failures.push(error);
    },
    unsupported: (op) => {
      unavailable.push(op);
    },
    planRefused: () => false,
    usageChanged: () => {},
    canChange: () => changeable,
    key: () => `port-key-${++key}`,
  });
  await reader.load("a");
  return {
    reader,
    hold,
    failures,
    unavailable,
    calls,
    get: () => detail!,
    pending: () => detail?.pendingPorts?.map(({ port, action }) => ({ port, action })) ?? [],
    count: (op: string) => calls.filter((call) => call.op === op).length,
    disallow: () => {
      changeable = false;
    },
  };
}

type Fixture = Awaited<ReturnType<typeof fixture>>;
const actions: { action: PortAction; op: string; run: (f: Fixture, machine?: string) => Promise<boolean> }[] = [
  { action: "forward", op: CloudOps.portForward, run: (f, machine = "a") => f.reader.forwardPort(machine, 3000) },
  { action: "close", op: CloudOps.portClose, run: (f, machine = "a") => f.reader.closePort(machine, 3000) },
  {
    action: "browser",
    op: CloudOps.browserOpen,
    run: (f, machine = "a") => f.reader.openBrowser(machine, 3000, "Example"),
  },
];

describe("Cloud port action boundaries", () => {
  test("forward locks synchronously, excludes conflicting actions, and permits another port", async () => {
    const f = await fixture();
    const first = f.hold(CloudOps.portForward);
    const running = f.reader.forwardPort("a", 3000);
    expect(f.pending()).toEqual([{ port: 3000, action: "forward" }]);
    expect(await f.reader.forwardPort("a", 3000)).toBe(false);
    expect(await f.reader.closePort("a", 3000)).toBe(false);
    expect(await f.reader.openBrowser("a", 3000, "Example")).toBe(false);
    expect(f.count(CloudOps.portForward)).toBe(1);
    expect(f.count(CloudOps.portClose)).toBe(0);
    expect(f.count(CloudOps.browserOpen)).toBe(0);
    expect(await f.reader.forwardPort("a", 4000)).toBe(true);
    expect(f.pending()).toEqual([{ port: 3000, action: "forward" }]);
    first.resolve(forward());
    expect(await running).toBe(true);
    expect(f.pending()).toEqual([]);
    expect(
      f
        .get()
        .ports?.map((entry) => entry.port)
        .sort(),
    ).toEqual([3000, 4000]);
  });

  test("close stays pending until the acknowledged close's list reconciliation finishes", async () => {
    const f = await fixture();
    const close = f.hold(CloudOps.portClose);
    const reload = f.hold(CloudOps.portList);
    const running = f.reader.closePort("a", 3000);
    expect(await f.reader.closePort("a", 3000)).toBe(false);
    close.resolve(null);
    await reload.started;
    expect(f.pending()).toEqual([{ port: 3000, action: "close" }]);
    expect(await f.reader.closePort("a", 3000)).toBe(false);
    expect(f.count(CloudOps.portClose)).toBe(1);
    reload.resolve({ forwards: [] });
    expect(await running).toBe(true);
    expect(f.get().ports).toEqual([]);
    expect(f.pending()).toEqual([]);
  });

  test("browser stays pending through route discovery and the native tab call", async () => {
    const f = await fixture();
    const discovery = f.hold(CloudOps.browserOpen);
    const tab = f.hold(ACTION_RUN);
    const running = f.reader.openBrowser("a", 3000, "Example");
    expect(await f.reader.openBrowser("a", 3000, "Example")).toBe(false);
    discovery.resolve(route());
    const tabArgs = await tab.started;
    expect(tabArgs).toMatchObject({
      action: HostActions.browserTabOpen,
      args: { engine: "cef", machineStore: { machine: "a" } },
    });
    expect(f.get().browser).toEqual(route());
    expect(f.pending()).toEqual([{ port: 3000, action: "browser" }]);
    expect(await f.reader.openBrowser("a", 3000, "Example")).toBe(false);
    expect(await f.reader.closePort("a", 3000)).toBe(false);
    expect(f.count(CloudOps.browserOpen)).toBe(1);
    expect(f.count(ACTION_RUN)).toBe(1);
    tab.resolve({ confirmed: true });
    expect(await running).toBe(true);
    expect(f.pending()).toEqual([]);
  });

  for (const { action, op, run } of actions) {
    for (const unsupported of [false, true]) {
      test(`${action}: ${unsupported ? "unsupported" : "failed"} calls release the guard for retry`, async () => {
        const f = await fixture();
        const request = f.hold(op);
        const running = run(f);
        const error = pageError(
          unsupported ? "cmux.protocol.unknown_op" : "cmux.cloud.upstream_error",
          "Request refused",
        );
        request.reject(error);
        expect(await running).toBe(false);
        expect(f.pending()).toEqual([]);
        expect(f.failures).toEqual(unsupported ? [] : [error]);
        expect(f.unavailable).toEqual(unsupported ? [op] : []);
        expect(await run(f)).toBe(true);
        const keys = f.calls.filter((call) => call.op === op).map((call) => call.params.idempotency_key);
        expect(keys).toHaveLength(2);
        expect(keys[0]).not.toBe(keys[1]);
      });
    }

    for (const reject of [false, true]) {
      test(`${action}: A → B → A suppresses a late ${reject ? "failure" : "success"} and keeps the old request locked`, async () => {
        const f = await fixture();
        const request = f.hold(op);
        const running = run(f);
        await f.reader.load("b");
        expect(f.pending()).toEqual([]);
        expect(await run(f, "b")).toBe(true);
        await f.reader.load("a");
        expect(f.pending()).toEqual([{ port: 3000, action }]);
        expect(await run(f)).toBe(false);
        const before = { ports: f.get().ports, browser: f.get().browser };
        const listCalls = f.count(CloudOps.portList);
        const tabCalls = f.count(ACTION_RUN);
        if (reject) request.reject(pageError("cmux.protocol.unknown_op", "Late failure"));
        else
          request.resolve(
            action === "forward" ? { ...forward(), localPort: 65000 } : action === "browser" ? route() : null,
          );
        expect(await running).toBe(false);
        expect({ ports: f.get().ports, browser: f.get().browser }).toEqual(before);
        expect(f.count(CloudOps.portList)).toBe(listCalls + (action === "browser" ? 0 : 1));
        expect(f.count(ACTION_RUN)).toBe(tabCalls);
        expect(f.failures).toEqual([]);
        expect(f.unavailable).toEqual([]);
        expect(f.pending()).toEqual([]);
      });
    }
  }

  for (const action of ["forward", "close"] as const) {
    test(`${action}: a parked mutation reconciles after switching A → B → A`, async () => {
      const f = await fixture();
      const request = f.hold(action === "forward" ? CloudOps.portForward : CloudOps.portClose);
      const running = action === "forward" ? f.reader.forwardPort("a", 4000) : f.reader.closePort("a", 3000);
      await f.reader.load("b");
      // The port list arrives before the mutation, but the overall load still
      // waits for snapshots. Its old list must not overwrite reconciliation.
      const snapshots = f.hold(CloudOps.snapshotList);
      const loading = f.reader.load("a");
      await snapshots.started;
      const after = action === "forward" ? [forward(), forward("a", 4000)] : [];
      const reconciliation = f.hold(CloudOps.portList);
      reconciliation.resolve({ forwards: after });
      request.resolve(action === "forward" ? forward("a", 4000) : null);
      expect(await running).toBe(false);
      expect(f.get().ports).toEqual(after);
      expect(f.pending()).toEqual([]);
      snapshots.resolve({ snapshots: [] });
      await loading;
      expect(f.get().ports).toEqual(after);
    });
  }

  for (const outcome of ["unsupported", "refused", "declined"] as const) {
    test(`browser ${outcome} releases pending and retains the proxied route for retry`, async () => {
      const f = await fixture();
      const tab = f.hold(ACTION_RUN);
      const running = f.reader.openBrowser("a", 3000, "Example");
      await tab.started;
      if (outcome === "declined") tab.resolve({ confirmed: false });
      else
        tab.reject(
          pageError(outcome === "unsupported" ? "cmux.app.unknown_action" : "cmux.browser.cef_unavailable", "No tab"),
        );
      expect(await running).toBe(false);
      expect(f.pending()).toEqual([]);
      expect(f.get().browser).toEqual(route());
      expect(f.get().browserRefused).toBe(outcome === "refused" ? true : undefined);
      expect(f.unavailable).toEqual(outcome === "unsupported" ? [HostActions.browserTabOpen] : []);
      expect(f.failures).toEqual([]);
      expect(await f.reader.openBrowser("a", 3000, "Example")).toBe(true);
      expect(f.get().browserRefused).toBeUndefined();
    });
  }

  test("a tab failure arriving after selection changes cannot mark the new machine unavailable", async () => {
    const f = await fixture();
    const tab = f.hold(ACTION_RUN);
    const running = f.reader.openBrowser("a", 3000, "Example");
    await tab.started;
    await f.reader.load("b");
    tab.reject(pageError("cmux.app.unknown_action", "Late unavailable"));
    expect(await running).toBe(false);
    expect(f.unavailable).toEqual([]);
    expect(f.get().machine).toBe("b");
    expect(f.get().browser).toBeUndefined();
    expect(f.pending()).toEqual([]);
  });

  test("an old session's finally cannot release a new session's same-port request", async () => {
    const f = await fixture();
    const old = f.hold(CloudOps.portForward);
    const oldRun = f.reader.forwardPort("a", 3000);
    await f.reader.load(undefined);
    await f.reader.load("a");
    const current = f.hold(CloudOps.portForward);
    const currentRun = f.reader.forwardPort("a", 3000);
    old.resolve({ ...forward(), localPort: 65000 });
    expect(await oldRun).toBe(false);
    expect(f.pending()).toEqual([{ port: 3000, action: "forward" }]);
    expect(await f.reader.forwardPort("a", 3000)).toBe(false);
    current.resolve(forward());
    expect(await currentRun).toBe(true);
    expect(f.pending()).toEqual([]);
    expect(f.get().ports?.[0]?.localPort).toBe(13000);
  });

  test("detail load and section reload preserve an action begun during the read", async () => {
    const f = await fixture();
    const initialList = f.hold(CloudOps.portList);
    const loading = f.reader.load("a");
    const request = f.hold(CloudOps.portForward);
    const running = f.reader.forwardPort("a", 4000);
    initialList.resolve({ forwards: [forward()] });
    await loading;
    expect(f.pending()).toEqual([{ port: 4000, action: "forward" }]);
    await f.reader.reload("ports");
    expect(f.pending()).toEqual([{ port: 4000, action: "forward" }]);
    expect(await f.reader.forwardPort("a", 4000)).toBe(false);
    request.resolve(forward("a", 4000));
    expect(await running).toBe(true);
    expect(f.pending()).toEqual([]);
    expect(f.get().ports?.map((entry) => entry.port)).toEqual([3000, 4000]);
  });

  for (const action of ["forward", "close"] as const) {
    test(`detail load cannot replace a completed ${action} with its older port list`, async () => {
      const f = await fixture();
      const snapshots = f.hold(CloudOps.snapshotList);
      const loading = f.reader.load("a");
      await snapshots.started;
      if (action === "forward") {
        expect(await f.reader.forwardPort("a", 4000)).toBe(true);
      } else {
        const reconciled = f.hold(CloudOps.portList);
        const closing = f.reader.closePort("a", 3000);
        await reconciled.started;
        reconciled.resolve({ forwards: [] });
        expect(await closing).toBe(true);
      }
      const expected = action === "forward" ? [forward(), forward("a", 4000)] : [];
      snapshots.resolve({ snapshots: [] });
      await loading;
      expect(f.get().ports).toEqual(expected);
      expect(f.pending()).toEqual([]);
    });
  }

  test("a failed close reconciliation releases the guard and reports the read error", async () => {
    const f = await fixture();
    const reload = f.hold(CloudOps.portList);
    const running = f.reader.closePort("a", 3000);
    await reload.started;
    const error = pageError("cmux.cloud.upstream_error", "Refresh failed");
    reload.reject(error);
    await running;
    expect(f.pending()).toEqual([]);
    expect(f.failures).toEqual([error]);
    expect(await f.reader.closePort("a", 3000)).toBe(true);
  });

  test("actions for an unselected machine or unavailable connection never acquire a guard", async () => {
    const f = await fixture();
    for (const { run } of actions) expect(await run(f, "b")).toBe(false);
    f.disallow();
    for (const { run } of actions) expect(await run(f)).toBe(false);
    expect(f.pending()).toEqual([]);
    for (const { op } of actions) expect(f.count(op)).toBe(0);
  });
});
