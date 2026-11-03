import { expect, test } from "bun:test";
import { fireEvent, render } from "@testing-library/react";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore } from "./store";
test("Row tap dispatches the node event", () => {
  const store = new SceneStore();
  store.apply([{ op: "create", id: "root", type: "VStack" }, { op: "create", id: "row", type: "Row", props: { title: "Recent PRs", onTap: true } }, { op: "children", id: "root", children: ["row"] }, { op: "root", id: "root" }]);
  const calls: unknown[][] = []; const view = render(<SceneRenderer store={store} dispatch={(...args) => calls.push(args)} />);
  fireEvent.click(view.getByText("Recent PRs")); expect(calls).toEqual([["row", "tap"]]);
});
