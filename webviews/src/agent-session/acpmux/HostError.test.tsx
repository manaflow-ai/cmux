// A chat refused because another binary's acpmux holds this app's socket (2026-10-22: with only
// Retry, which asked the same daemon again) offers Restart acpmux beside Retry.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HostError } from "./HostError";

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

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")].map((b) => b.textContent);

test("a refusal another binary's acpmux caused offers Restart acpmux beside Retry", async () => {
  const container = installDom();
  const pressed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostError
        message="acpmux is running at /h/acpmux.sock, but this build may not use it."
        onRetry={() => pressed.push("retry")}
        onRestart={() => pressed.push("restart")}
      />,
    );
  });
  expect(buttons(container)).toEqual(["Restart acpmux", "Retry"]);
  // The hint says what the restart does, not that cmux keeps trying.
  expect(container.textContent).toContain("starts the one in this app");
  await act(async () => container.querySelector("button")!.click());
  expect(pressed).toEqual(["restart"]);
});

test("a restart in flight holds both buttons", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostError message="refused" onRetry={() => undefined} onRestart={() => undefined} restarting />);
  });
  expect(buttons(container)).toEqual(["Restarting acpmux…", "Retry"]);
  expect([...container.querySelectorAll("button")].every((b) => b.disabled)).toBe(true);
});

test("without the offer the card keeps only Retry and says cmux tries again", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostError message="The agent host is unavailable." onRetry={() => undefined} />);
  });
  expect(buttons(container)).toEqual(["Retry"]);
  expect(container.textContent).toContain("cmux tries again on its own");
});
