import { describe, expect, test } from "bun:test";
import { SceneStore, type SceneOp } from "./store";
describe("SceneStore", () => {
  test("applies create, update null deletes, children and root", () => {
    const store = new SceneStore();
    const ops: SceneOp[] = [
      { op: "create", id: "root", type: "VStack", props: { spacing: 8, old: true } },
      { op: "create", id: "row", type: "Row", props: { title: "PR" } },
      { op: "children", id: "root", children: ["row"] }, { op: "root", id: "root" },
      { op: "update", id: "root", props: { spacing: 4, old: null } },
    ];
    store.apply(ops);
    expect(store.getRoot()).toBe("root"); expect(store.getNode("root")?.props).toEqual({ spacing: 4 });
    expect(store.getNode("root")?.children).toEqual(["row"]);
    store.apply([], true);
    expect(store.getRoot()).toBeUndefined();
    expect(store.getNode("row")).toBeUndefined();
  });
  test("removes a subtree and detaches it", () => {
    const store = new SceneStore();
    store.apply([{ op: "create", id: "root", type: "VStack" }, { op: "create", id: "a", type: "Group" }, { op: "create", id: "b", type: "Text" }, { op: "children", id: "root", children: ["a"] }, { op: "children", id: "a", children: ["b"] }, { op: "root", id: "root" }, { op: "remove", id: "a" }]);
    expect(store.getNode("a")).toBeUndefined(); expect(store.getNode("b")).toBeUndefined(); expect(store.getNode("root")?.children).toEqual([]);
  });
});
