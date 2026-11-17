import { expect, test } from "bun:test";
import type { PageClient, PageHandler } from "../../pages/shared/pageClient";
import { pageError } from "../../pages/shared/pageClient";
import { AppPanelsClient, bundleAssetURL, type AppPanel, type SceneEvent } from "./panelsClient";
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

const WIDGET_OPTIONS = {
  interface: "cmux.newtab.widget/1",
  limits: { maxNodes: 4, types: new Set(["VStack", "Text"]) },
  mounts: (panel: AppPanel, layout: readonly string[]) => layout.includes(`app:${panel.app}#${panel.section}`),
};

test("New Tab widgets list their interface, mount only placed ones and save the layout", async () => {
  const mock = new MockAppPanelsClient();
  const owner = new AppPanelsClient(mock, { surface: "newTab" }, WIDGET_OPTIONS);
  owner.start();
  await settled();
  await settled();
  // Listed for Add Widgets, nothing placed: no mount (R1).
  expect(owner.getView().panels.length).toBe(3);
  expect(owner.getView().mounted).toEqual([]);
  expect(mock.mounted).toBe(0);
  const clock = "app:manaflow-ai/clock#cmux.newtab.widget/1";
  owner.setLayout(["timer", clock]);
  expect(mock.savedLayouts).toEqual([["timer", clock]]);
  expect(owner.getView().layout).toEqual(["timer", clock]);
  await settled();
  await settled();
  expect(mock.mounted).toBe(1);
  expect(owner.getView().mounted.map((entry) => entry.panel.app)).toEqual(["manaflow-ai/clock"]);
  owner.setLayout(["timer"]);
  expect(mock.mounted).toBe(0);
  owner.stop();
});

test("a widget over its limits is unmounted and named; a failed mount is named and not retried in a loop", async () => {
  const mock = new MockAppPanelsClient();
  mock.failing.add("samples/github-prs");
  mock.layout = ["app:samples/too-big#cmux.newtab.widget/1", "app:samples/github-prs#cmux.newtab.widget/1"];
  const owner = new AppPanelsClient(mock, { surface: "newTab" }, WIDGET_OPTIONS);
  owner.start();
  for (let i = 0; i < 4; i++) await settled();
  const problems = Object.fromEntries(owner.getView().mounted.map((entry) => [entry.panel.app, entry.problem]));
  expect(problems["samples/too-big"]).toEqual({ kind: "over", violation: { kind: "nodes", limit: 4 } });
  expect(problems["samples/github-prs"]).toEqual({ kind: "failed" });
  // The over-budget mount ended; the failed one never mounted.
  expect(mock.mounted).toBe(0);
  owner.stop();
});

test("hiding the page ends every widget mount", async () => {
  const mock = new MockAppPanelsClient();
  mock.layout = ["app:manaflow-ai/clock#cmux.newtab.widget/1"];
  const owner = new AppPanelsClient(mock, { surface: "newTab" }, WIDGET_OPTIONS);
  owner.start();
  for (let i = 0; i < 4; i++) await settled();
  expect(mock.mounted).toBe(1);
  owner.stop();
  expect(mock.mounted).toBe(0);
});

test("a host that ignores the interface lists no widgets and offers no edits", async () => {
  const mock = new MockAppPanelsClient();
  mock.ignoresInterface = true; // it answers with Session Info's sections and no layout
  const owner = new AppPanelsClient(mock, { surface: "newTab" }, WIDGET_OPTIONS);
  owner.start();
  for (let i = 0; i < 4; i++) await settled();
  expect(owner.getView().panels).toEqual([]);
  expect(owner.getView().editable).toBe(false);
  owner.setLayout(["app:samples/github-prs#recent"]);
  expect(mock.savedLayouts).toEqual([]);
  expect(owner.getView().layout).toEqual([]);
  expect(mock.mounted).toBe(0);
  owner.stop();
});

test("a host that refuses layout.set ends edits and keeps the row it listed", async () => {
  const mock = new MockAppPanelsClient();
  mock.refusesLayout = true;
  const owner = new AppPanelsClient(mock, { surface: "newTab" }, WIDGET_OPTIONS);
  owner.start();
  for (let i = 0; i < 4; i++) await settled();
  expect(owner.getView().editable).toBe(true);
  owner.setLayout(["app:manaflow-ai/clock#cmux.newtab.widget/1"]);
  for (let i = 0; i < 4; i++) await settled();
  expect(owner.getView().editable).toBe(false);
  expect(owner.getView().layout).toEqual([]);
  expect(mock.mounted).toBe(0);
  // A later list does not bring edits back.
  await owner.refresh();
  expect(owner.getView().editable).toBe(false);
  owner.stop();
});

test("mount names its surface; status events reach the scene store and Reload calls the host from the click", async () => {
  const host = new Host();
  host.mount = Promise.resolve({ mount_id: "mount-a" });
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(host.calls.find((call) => call.op === "cmux.apps.panels.mount")?.params).toEqual({
    surface: "sessionInfoSection",
    app: PANEL.app,
    section: PANEL.section,
    context: CONTEXT,
  });
  const mounted = owner.getSnapshot()[0]!;
  expect(mounted.store.getStatus().state).toBe("loading");
  host.scene?.({ mount_id: "mount-a", status: "failed", reason: "init: Error: nope" }, 1);
  expect(mounted.store.getStatus()).toEqual({ state: "failed", reason: "init: Error: nope" });
  host.scene?.({ mount_id: "someone-else", status: "ready" }, 2);
  expect(mounted.store.getStatus().state).toBe("failed");
  const before = host.calls.length;
  mounted.reload();
  // Recorded before any await: the host checks its own recent gesture.
  expect(host.calls.slice(before)).toEqual([{ op: "cmux.apps.panels.reload", params: { mount_id: "mount-a" } }]);
  host.scene?.(
    {
      mount_id: "mount-a",
      ops: [
        { op: "create", id: "t", type: "Text", props: { text: "Back" } },
        { op: "root", id: "t" },
      ],
      reset: true,
    },
    3,
  );
  expect(mounted.store.getStatus().state).toBe("ready");
  host.scene?.({ mount_id: "mount-a", status: "disconnected", reason: "cmux is not connected" }, 4);
  expect(mounted.store.getStatus()).toEqual({ state: "disconnected", reason: "cmux is not connected" });
  owner.stop();
  mounted.reload();
  expect(host.count("reload")).toBe(1);
});

test("layout reports each new drawn height once, rounded up, and nothing after close", async () => {
  const host = new Host();
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  const mounted = owner.getSnapshot()[0]!;
  mounted.layout(120.2);
  mounted.layout(120.9);
  mounted.layout(64);
  mounted.layout(Number.NaN);
  expect(host.calls.filter((call) => call.op === "cmux.apps.panels.layout").map((call) => call.params)).toEqual([
    { mount_id: "mount-a", height: 121 },
    { mount_id: "mount-a", height: 64 },
  ]);
  owner.stop();
  mounted.layout(80);
  expect(host.count("layout")).toBe(2);
});

test("bundle images resolve under the mount's asset base only when the host serves them", async () => {
  const host = new Host();
  host.mount = Promise.resolve({ mount_id: "mount-a", asset_base: "/__appbundle/mount-a/" });
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  const mounted = owner.getSnapshot()[0]!;
  expect(mounted.resolveAsset("assets/logo one.png")).toBe("/__appbundle/mount-a/assets/logo%20one.png");
  expect(mounted.resolveAsset("assets/a%2Fb.png")).toBeUndefined();
  expect(bundleAssetURL("/b/", "x/%2e%2e/y.png")).toBeUndefined();
  expect(bundleAssetURL("/b/", "%E0%A4%A.png")).toBeUndefined();
  owner.stop();
  const bare = new Host();
  const other = new AppPanelsClient(bare, CONTEXT);
  other.start();
  await settled();
  await settled();
  expect(other.getSnapshot()[0]!.resolveAsset("assets/logo.png")).toBeUndefined();
  other.stop();
});

test("a refused mount shows its reason as a failure", async () => {
  const host = new Host();
  host.mount = Promise.reject(
    pageError("cmux.apps.panels.not_found", "No sessionInfoSection of local/customize#prs shows"),
  );
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  expect(owner.getSnapshot()[0]!.store.getStatus()).toEqual({
    state: "failed",
    reason: "No sessionInfoSection of local/customize#prs shows",
  });
  owner.stop();
});

test("a height measured before the mount answers reaches the host once it does", async () => {
  const host = new Host();
  const mount = deferred<unknown>();
  host.mount = mount.promise;
  const owner = new AppPanelsClient(host, CONTEXT);
  owner.start();
  await settled();
  await settled();
  owner.getSnapshot()[0]!.layout(40);
  expect(host.count("layout")).toBe(0);
  mount.resolve({ mount_id: "mount-a" });
  await settled();
  await settled();
  expect(host.calls.filter((call) => call.op === "cmux.apps.panels.layout").map((call) => call.params)).toEqual([
    { mount_id: "mount-a", height: 40 },
  ]);
  owner.stop();
});
