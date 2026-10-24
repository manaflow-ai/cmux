// A page menu (History's row menu) in the app is the app's standard macOS menu: it hands the rows
// and the pointer to the host, draws nothing in the page, and runs the chosen row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PageMenu } from "./PageMenu";
import { installNativeMenu, type NativeMenuRequest } from "../../ui/nativeMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  installNativeMenu(null);
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("a page menu opens the app's native menu and runs the chosen row", async () => {
  const asked: NativeMenuRequest[] = [];
  const ran: string[] = [];
  let closed = 0;
  installNativeMenu(async (request) => {
    asked.push(request);
    return { picked: "remove" };
  });
  root = createRoot(installDom());
  await act(async () => {
    root!.render(
      <PageMenu
        x={12}
        y={34}
        items={[
          { id: "open", label: "Open", run: () => ran.push("open") },
          { id: "remove", label: "Remove", separatorBefore: true, destructive: true, run: () => ran.push("remove") },
        ]}
        onClose={() => closed++}
      />,
    );
    await Promise.resolve();
  });
  expect(asked).toEqual([
    {
      items: [
        { id: "open", label: "Open" },
        { id: "separator:remove", label: "", separator: true },
        { id: "remove", label: "Remove" },
      ],
      point: { x: 12, y: 34 },
    },
  ]);
  expect(document.querySelector(".page-menu")).toBeNull();
  expect(ran).toEqual(["remove"]);
  expect(closed).toBe(1);
});
