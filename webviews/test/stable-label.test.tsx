import { afterEach, expect, test } from "bun:test";
import { createRoot, type Root } from "react-dom/client";
import { act } from "react";
import { JSDOM } from "jsdom";
import { StableLabel } from "../src/ui/StableLabel";

let dom: JSDOM | undefined;
let root: Root | undefined;

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
});

test("StableLabel reserves every translated action state without duplicating accessible text", () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const container = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(container);
    root!.render(<StableLabel reserve={["Reconnecting…", "Try again"]}>Reconnect</StableLabel>);
  });
  expect(container.querySelector(".ui-stable-label")?.textContent).toBe("ReconnectReconnecting…Try again");
  expect(container.querySelector(".ui-stable-label__current")?.textContent).toBe("Reconnect");
  expect(container.querySelectorAll(".ui-stable-label__reserve")).toHaveLength(2);
  expect(
    [...container.querySelectorAll(".ui-stable-label__reserve")].every(
      (node) => node.getAttribute("aria-hidden") === "true",
    ),
  ).toBe(true);
});
