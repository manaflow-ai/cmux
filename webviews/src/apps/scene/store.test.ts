import { describe, expect, test } from "bun:test";
import { SceneStore, type SceneOp } from "./store";

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
