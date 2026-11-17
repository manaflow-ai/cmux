import { describe, expect, test } from "bun:test";
import { SCENE_LOADING, SceneStore, sceneStatusReducer, type SceneOp } from "./store";

function graph(): SceneStore {
  const store = new SceneStore();
  store.apply([
    { op: "create", id: "root", type: "VStack", props: { spacing: 8, stale: null } },
    { op: "create", id: "a", type: "Group" },
    { op: "create", id: "b", type: "Row", props: { title: "PR", subtitle: "Before" } },
    { op: "create", id: "c", type: "Row", props: { title: "Other" } },
    { op: "children", id: "root", children: ["a", "c"] },
    { op: "children", id: "a", children: ["b"] },
    { op: "root", id: "root" },
  ]);
  return store;
}

describe("SceneStore", () => {
  test("applies ordered operations; partial updates delete null props without mutating snapshots", () => {
    const store = graph();
    const before = store.getNode("b");
    store.apply([{ op: "update", id: "b", props: { title: "After", subtitle: null } }]);
    expect(store.getNode("b")?.props).toEqual({ title: "After" });
    expect(before?.props).toEqual({ title: "PR", subtitle: "Before" });
    expect(store.getNode("root")?.props).toEqual({ spacing: 8 });
    store.apply([{ op: "children", id: "root", children: ["c", "a"] }]);
    expect(store.getNode("root")?.children).toEqual(["c", "a"]);
  });

  test("notifies only changed node subscribers once per batch, and keeps unrelated identities", () => {
    const store = graph();
    const unchanged = store.getNode("c");
    const calls: string[] = [];
    const stops = ["root", "a", "b", "c"].map((id) => store.subscribeNode(id, () => calls.push(id)));
    const rootStop = store.subscribeRoot(() => calls.push("root-id"));
    store.apply([
      { op: "update", id: "b", props: { title: "One" } },
      { op: "update", id: "b", props: { title: "Two" } },
    ]);
    expect(calls).toEqual(["b"]);
    expect(store.getNode("c")).toBe(unchanged);
    expect(store.getNode("b")?.props.title).toBe("Two");
    stops.forEach((stop) => stop());
    rootStop();
    store.apply([{ op: "update", id: "b", props: { title: "Three" } }]);
    expect(calls).toEqual(["b"]);
  });

  test("reparents children and removes only the current subtree", () => {
    const store = graph();
    store.apply([{ op: "children", id: "c", children: ["b"] }]);
    expect(store.getNode("a")?.children).toEqual([]);
    expect(store.getNode("c")?.children).toEqual(["b"]);
    store.apply([{ op: "remove", id: "a" }]);
    expect(store.getNode("b")?.props.title).toBe("PR");
    expect(store.getNode("root")?.children).toEqual(["c"]);
    store.apply([{ op: "remove", id: "c" }]);
    expect(store.getNode("b")).toBeUndefined();
    expect(store.getNode("root")?.children).toEqual([]);
  });

  test("skips missing, duplicate, self and cyclic children", () => {
    const store = graph();
    store.apply([
      { op: "children", id: "root", children: ["missing", "c", "c", "root", "a"] },
      { op: "children", id: "b", children: ["root"] },
    ]);
    expect(store.getNode("root")?.children).toEqual(["c", "a"]);
    expect(store.getNode("b")?.children).toEqual([]);
  });

  test("reset clears a mount and publishes replacement nodes even with the same root id", () => {
    const store = graph();
    const calls: string[] = [];
    store.subscribeNode("b", () => calls.push("b"));
    store.subscribeNode("root", () => calls.push("root"));
    store.apply(
      [
        { op: "create", id: "root", type: "Text", props: { text: "Reloaded" } },
        { op: "root", id: "root" },
      ],
      true,
    );
    expect(store.getRoot()).toBe("root");
    expect(store.getNode("root")?.props.text).toBe("Reloaded");
    expect(store.getNode("b")).toBeUndefined();
    expect(calls.sort()).toEqual(["b", "root"]);
    store.apply([], true);
    expect(store.getRoot()).toBeUndefined();
    expect(store.getNode("root")).toBeUndefined();
  });

  test("refuses an attachment whose existing subtree would exceed the depth budget", () => {
    const store = new SceneStore();
    const ops: SceneOp[] = [];
    for (let index = 0; index < 65; index++) ops.push({ op: "create", id: String(index), type: "VStack" });
    for (let index = 63; index >= 0; index--)
      ops.push({ op: "children", id: String(index), children: [String(index + 1)] });
    store.apply(ops);
    // 1..64 is a valid 64-deep tree; attaching it below 0 is refused as a whole.
    expect(store.getNode("0")?.children).toEqual([]);
    expect(store.getNode("1")?.children).toEqual(["2"]);
  });
});

test("depth validation follows cached subtree heights after deleting equal-height branches", () => {
  const store = new SceneStore();
  const ops: SceneOp[] = [
    { op: "create", id: "root", type: "VStack" },
    { op: "create", id: "above", type: "VStack" },
  ];
  for (const branch of ["a", "b"]) {
    for (let index = 0; index < 63; index++) ops.push({ op: "create", id: `${branch}${index}`, type: "VStack" });
    for (let index = 61; index >= 0; index--)
      ops.push({ op: "children", id: `${branch}${index}`, children: [`${branch}${index + 1}`] });
  }
  ops.push({ op: "children", id: "root", children: ["a0", "b0"] });
  store.apply(ops);
  store.apply([
    { op: "remove", id: "a0" },
    { op: "children", id: "above", children: ["root"] },
  ]);
  // The other equally tall branch still makes root 64 deep.
  expect(store.getNode("above")?.children).toEqual([]);
  store.apply([
    { op: "remove", id: "b0" },
    { op: "children", id: "above", children: ["root"] },
  ]);
  expect(store.getNode("above")?.children).toEqual(["root"]);
});

test("a contribution's limits drop nodes past them and record why", () => {
  const capped = new SceneStore({ maxNodes: 2 });
  capped.apply([
    { op: "create", id: "a", type: "Text" },
    { op: "create", id: "b", type: "Text" },
    { op: "create", id: "c", type: "Text" },
  ]);
  expect(capped.getNode("c")).toBeUndefined();
  expect(capped.violation).toEqual({ kind: "nodes", limit: 2 });
  const typed = new SceneStore({ types: new Set(["Text"]) });
  typed.apply([{ op: "create", id: "img", type: "Image" }]);
  expect(typed.getNode("img")).toBeUndefined();
  expect(typed.violation).toEqual({ kind: "type", type: "Image" });
  typed.apply(
    [
      { op: "create", id: "t", type: "Text" },
      { op: "root", id: "t" },
    ],
    true,
  );
  expect(typed.violation).toBeUndefined();
  // No limits: the host's own cap only, and no violation.
  expect(new SceneStore().violation).toBeUndefined();
});

describe("scene status", () => {
  const scene: SceneOp[] = [
    { op: "create", id: "root", type: "Text", props: { text: "Hi" } },
    { op: "root", id: "root" },
  ];

  test("the reducer follows the host model: a root readies a loading mount, a reset loads again", () => {
    expect(sceneStatusReducer(SCENE_LOADING, { type: "scene", hasRoot: false })).toBe(SCENE_LOADING);
    const ready = sceneStatusReducer(SCENE_LOADING, { type: "scene", hasRoot: true });
    expect(ready).toEqual({ state: "ready" });
    expect(sceneStatusReducer(ready, { type: "scene", hasRoot: true })).toBe(ready);
    const failed = sceneStatusReducer(ready, { type: "status", status: "failed", reason: "boom" });
    expect(failed).toEqual({ state: "failed", reason: "boom" });
    // A batch does not clear a failure; only the host or a reset does.
    expect(sceneStatusReducer(failed, { type: "scene", hasRoot: true })).toBe(failed);
    expect(sceneStatusReducer(failed, { type: "status", status: "failed", reason: "boom" })).toBe(failed);
    expect(sceneStatusReducer(failed, { type: "reset" })).toBe(SCENE_LOADING);
    expect(sceneStatusReducer(ready, { type: "status", status: "disconnected", reason: "offline" })).toEqual({
      state: "disconnected",
      reason: "offline",
    });
    expect(sceneStatusReducer(ready, { type: "status", status: "exploded" })).toBe(ready);
  });

  test("the store publishes each status change once; a reset scene after a failure goes straight to ready", () => {
    const store = new SceneStore();
    const seen: string[] = [];
    const stop = store.subscribeStatus(() => seen.push(store.getStatus().state));
    expect(store.getStatus()).toBe(SCENE_LOADING);
    store.apply(scene);
    expect(seen).toEqual(["ready"]);
    store.apply([{ op: "update", id: "root", props: { text: "Again" } }]);
    store.setStatus("ready");
    expect(seen).toEqual(["ready"]);
    store.setStatus("failed", "main: Error: nope");
    expect(store.getStatus()).toEqual({ state: "failed", reason: "main: Error: nope" });
    store.apply([{ op: "update", id: "root", props: { text: "Still failed" } }]);
    expect(store.getStatus().state).toBe("failed");
    store.apply(scene, true);
    expect(seen).toEqual(["ready", "failed", "ready"]);
    store.setStatus("loading");
    store.setStatus("disconnected", "cmux is not connected");
    expect(store.getStatus()).toEqual({ state: "disconnected", reason: "cmux is not connected" });
    // An empty reset (the host restarted the app) loads until its root lands.
    store.apply([], true);
    expect(store.getStatus()).toBe(SCENE_LOADING);
    expect(seen).toEqual(["ready", "failed", "ready", "loading", "disconnected", "loading"]);
    stop();
    store.setStatus("ready");
    expect(seen).toHaveLength(6);
  });
});
