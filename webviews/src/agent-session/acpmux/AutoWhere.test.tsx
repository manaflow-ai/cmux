import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AutoAddingMachineLine } from "./AutoWhere";
import { autoAddingMachineLine } from "./autoWhereModel";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[key];
    else (globalThis as Record<string, unknown>)[key] = value;
  }
  saved.clear();
});

test("the scale-up line renders in Auto styling and clears with the warning", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  const container = dom.window.document.getElementById("root")!;
  const globals = {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, (globalThis as Record<string, unknown>)[key]);
    (globalThis as Record<string, unknown>)[key] = value;
  }
  root = createRoot(container);
  const text = autoAddingMachineLine({ scalingUp: true });
  expect(text).toBe("Auto is adding a machine");
  await act(async () =>
    root!.render(text ? <AutoAddingMachineLine text={text} look="orbit" /> : null),
  );
  expect(container.querySelector(".acpmux-auto-arrival")?.textContent).toContain("Auto is adding a machine");
  expect(container.querySelector("[data-auto-look=orbit]")).not.toBeNull();
  await act(async () => root!.render(null));
  expect(container.querySelector(".acpmux-auto-arrival")).toBeNull();
});
