import { expect, test } from "bun:test";
import type { PageClient, PageHandler } from "../../pages/shared/pageClient";
import { pageError } from "../../pages/shared/pageClient";
import { AppPanelsClient, type AppPanel, type SceneEvent } from "./panelsClient";
import { MOCK_APP_PANELS, MockAppPanelsClient } from "./panelsMock";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
const PANEL: AppPanel = { app: "local/customize", section: "prs", title: "Recent PRs" };
const CONTEXT = { session_id: "chat-a", cwd: "/projects/atlas" };
/** Flush only the promises the fake host has already resolved, with no timers or polling. */
async function settled() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

class Host implements PageClient {
  readonly calls: { op: string; params: unknown }[] = [];
  lists: Promise<unknown>[] = [];
  mount = Promise.resolve<unknown>({ mount_id: "mount-a" });
  sceneReady = Promise.resolve<() => void>(() => {
    this.sceneStopped++;
  });
  changedReady = Promise.resolve<() => void>(() => {
    this.changedStopped++;
  });
  sceneStopped = 0;
  changedStopped = 0;
  scene?: (event: SceneEvent, seq: number) => void;
  changed?: () => void;
  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (op === "cmux.apps.panels.list")
      return (await (this.lists.shift() ?? Promise.resolve({ panels: [PANEL] }))) as R;
    if (op === "cmux.apps.panels.mount") return (await this.mount) as R;
    return {} as R;
  }
  async subscribe<E>(
    stream: string,
    callback: (event: E, seq: number) => void,
    filter?: Record<string, unknown>,
  ): Promise<() => void> {
    if (stream === "cmux.apps.panels.changed") {
      this.changed = () => callback(undefined as E, 1);
      return this.changedReady;
    }
    expect(filter).toEqual({ mount_id: "mount-a" });
    this.scene = callback as (event: SceneEvent, seq: number) => void;
    return this.sceneReady;
  }
  handle(_op: string, _handler: PageHandler) {
    return () => undefined;
  }
  count(op: string) {
    return this.calls.filter((call) => call.op === `cmux.apps.panels.${op}`).length;
  }
}

test("concurrent list updates keep one pending mount; metadata updates keep its scene", async () => {
  const host = new Host();
  const mount = deferred<unknown>();
  host.mount = mount.promise;
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(host.count("list")).toBe(2);
  await owner.refresh();
  expect(host.count("mount")).toBe(1);
  const scene = owner.getSnapshot()[0]!.store;
  host.lists.push(Promise.resolve({ panels: [{ ...PANEL, title: "Last day's PRs" }] }));
  await owner.refresh();
  expect(owner.getSnapshot()[0]!.panel.title).toBe("Last day's PRs");
  expect(owner.getSnapshot()[0]!.store).toBe(scene);
  mount.resolve({ mount_id: "mount-a" });
  await settled();
  owner.stop();
  expect(host.count("unmount")).toBe(1);
});

test("an older list response cannot restore an uninstalled section", async () => {
  const host = new Host();
  const old = deferred<unknown>();
  // The eager read stays pending; the post-subscribe read sees the uninstall first.
  host.lists.push(old.promise, Promise.resolve({ panels: [] }));
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(host.count("list")).toBe(2);
  old.resolve({ panels: [PANEL] });
  await settled();
  expect(owner.getSnapshot()).toEqual([]);
  expect(host.count("mount")).toBe(0);
  owner.stop();
});

test("removing a pending mount unmounts its late reply and never subscribes", async () => {
  const host = new Host();
  const mount = deferred<unknown>();
  host.mount = mount.promise;
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(host.count("list")).toBe(2);
  expect(host.count("mount")).toBe(1);
  host.lists.push(Promise.resolve({ panels: [] }));
  await owner.refresh();
  mount.resolve({ mount_id: "mount-a" });
  await settled();
  expect(host.scene).toBeUndefined();
  expect(host.count("unmount")).toBe(1);
  owner.stop();
  expect(host.count("unmount")).toBe(1);
});

test("late changed and scene subscription replies are stopped after pane close", async () => {
  const host = new Host();
  const changed = deferred<() => void>();
  const scene = deferred<() => void>();
  host.changedReady = changed.promise;
  host.sceneReady = scene.promise;
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(host.scene).toBeDefined();
  owner.stop();
  scene.resolve(() => {
    host.sceneStopped++;
  });
  changed.resolve(() => {
    host.changedStopped++;
  });
  await settled();
  expect(host.sceneStopped).toBe(1);
  expect(host.changedStopped).toBe(1);
  expect(host.count("unmount")).toBe(1);
  host.changed?.();
  expect(host.count("list")).toBe(1);
});

test("a rejected scene subscription releases its daemon mount", async () => {
  const host = new Host();
  const scene = deferred<() => void>();
  host.sceneReady = scene.promise;
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  scene.reject(pageError("cmux.protocol.unknown_op", "old host"));
  await settled();
  expect(host.count("unmount")).toBe(1);
  owner.stop();
  expect(host.count("unmount")).toBe(1);
});

test("old hosts and missing clients expose no app sections", async () => {
  const host = new Host();
  const list = deferred<unknown>();
  const changed = deferred<() => void>();
  host.lists.push(list.promise);
  host.changedReady = changed.promise;
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  list.reject(pageError("cmux.protocol.unknown_op", "old host"));
  changed.reject(pageError("cmux.protocol.unknown_op", "old host"));
  await settled();
  expect(owner.getSnapshot()).toEqual([]);
  expect(host.count("mount")).toBe(0);
  owner.stop();
  const absent = new AppPanelsClient(null, CONTEXT);
  absent.start();
  expect(absent.getSnapshot()).toEqual([]);
  absent.stop();
});

test("scene updates stay inside the scene store and dispatch names the owned mount", async () => {
  const host = new Host();
  const owner = new AppPanelsClient(host, CONTEXT);
  let listChanges = 0;
  const unsubscribe = owner.subscribe(() => {
    listChanges++;
  });
  owner.start();
  await settled();
  await settled();
  const snapshot = owner.getSnapshot();
  const before = listChanges;
  host.scene?.({ mount_id: "someone-else", ops: [{ op: "create", id: "bad", type: "Text" }] }, 1);
  host.scene?.(
    {
      mount_id: "mount-a",
      ops: [
        { op: "create", id: "row", type: "Row", props: { title: "Before" } },
        { op: "root", id: "row" },
      ],
    },
    2,
  );
  host.scene?.({ mount_id: "mount-a", ops: [{ op: "update", id: "row", props: { title: "After" } }] }, 3);
  expect(snapshot[0]!.store.getNode("bad")).toBeUndefined();
  expect(snapshot[0]!.store.getNode("row")?.props.title).toBe("After");
  expect(owner.getSnapshot()).toBe(snapshot);
  expect(listChanges).toBe(before);
  snapshot[0]!.dispatch("row", "tap", {});
  expect(host.calls.at(-1)).toEqual({
    op: "cmux.apps.panels.dispatch",
    params: { mount_id: "mount-a", node: "row", event: "tap", payload: {} },
  });
  owner.stop();
  snapshot[0]!.dispatch("row", "tap", {});
  expect(host.count("dispatch")).toBe(1);
  unsubscribe();
});

test("browser fixture exercises separate mounts and reset hot reload through PageClient", async () => {
  const host = new MockAppPanelsClient();
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(owner.getSnapshot()).toHaveLength(2);
  const prs = owner.getSnapshot()[0]!;
  const notes = owner.getSnapshot()[1]!;
  expect(prs.store.getNode("row-0")?.props.title).toBe("Keep chat drafts on reconnect");
  expect(notes.store.getNode("row-0")?.props.subtitle).toBe(CONTEXT.cwd);
  host.reload(MOCK_APP_PANELS[0]!, [
    { op: "create", id: "fresh", type: "Text", props: { text: "Edited app" } },
    { op: "root", id: "fresh" },
  ]);
  expect(prs.store.getRoot()).toBe("fresh");
  expect(prs.store.getNode("row-0")).toBeUndefined();
  expect(notes.store.getNode("row-0")?.props.title).toBe("Project");
  owner.stop();
});

test("a catalog change before the watch activates is recovered by its completion read", async () => {
  const host = new Host();
  const changed = deferred<() => void>();
  host.changedReady = changed.promise;
  host.lists.push(Promise.resolve({ panels: [] }));
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  expect(host.count("list")).toBe(1);
  expect(owner.getSnapshot()).toEqual([]);
  // An app appears while the host has not installed the watch. No changed event is delivered.
  host.lists.push(Promise.resolve({ panels: [PANEL] }));
  changed.resolve(() => {
    host.changedStopped++;
  });
  await settled();
  await settled();
  expect(host.count("list")).toBe(2);
  expect(owner.getSnapshot().map((entry) => entry.panel)).toEqual([PANEL]);
  expect(host.count("mount")).toBe(1);
  owner.stop();
  expect(host.changedStopped).toBe(1);
  expect(host.count("unmount")).toBe(1);
});
