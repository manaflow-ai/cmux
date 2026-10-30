// A host failure the pane says is one line above the composer with one small action and no
// recovery steps (Leo, 2026-10-29). A chat refused because another binary's acpmux holds this
// app's socket (2026-10-22: with only Retry, which asked the same daemon again) offers Restart acpmux.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HostError, HostUnavailableLine } from "./HostError";

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

test("a refusal another binary's acpmux caused is one line whose one action is Restart acpmux", async () => {
  const container = installDom();
  const pressed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostUnavailableLine
        message="acpmux belongs to cmux NIGHTLY, and this build may not use it."
        onRetry={() => pressed.push("retry")}
        onRestart={() => pressed.push("restart")}
      />,
    );
  });
  expect(buttons(container)).toEqual(["Restart acpmux"]);
  expect(container.querySelectorAll("p")).toHaveLength(1);
  expect(container.textContent).not.toContain("starts the one in this app");
  await act(async () => container.querySelector("button")!.click());
  expect(pressed).toEqual(["restart"]);
});

test("a restart in flight holds its button", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostUnavailableLine message="refused" onRetry={() => undefined} onRestart={() => undefined} restarting />,
    );
  });
  expect(buttons(container)).toEqual(["Restarting acpmux…"]);
  expect([...container.querySelectorAll("button")].every((b) => b.disabled)).toBe(true);
});

test("a queued Retry holds Restart acpmux until the handshake settles", async () => {
  const container = installDom();
  const pressed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostUnavailableLine
        message="socket closed"
        retrying
        onRetry={() => pressed.push("retry")}
        onRestart={() => pressed.push("restart")}
      />,
    );
  });
  const [restart] = [...container.querySelectorAll<HTMLButtonElement>("button")];
  expect(restart?.textContent).toBe("Restart acpmux");
  expect(restart?.disabled).toBe(true);
  await act(async () => restart?.click());
  expect(pressed).toEqual([]);
});

test("a late failure is its message and Retry, with no recovery steps", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostUnavailableLine message="acpmux did not answer in time." onRetry={() => undefined} />);
  });
  expect(buttons(container)).toEqual(["Retry"]);
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  expect(container.querySelectorAll("p")).toHaveLength(1);
  expect(container.textContent).toBe("acpmux did not answer in time.Retry");
  expect(container.textContent).not.toContain("tries again on its own");
  expect(container.textContent).not.toContain("stays here until");
  expect(container.querySelector(".cv-spinner__arc")).toBeNull();
});

test("a Retry waiting on the attempt in flight says so and holds", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<HostUnavailableLine message="acpmux did not answer in time." onRetry={() => undefined} retrying />);
  });
  expect(buttons(container)).toEqual(["Retrying…"]);
  expect(container.querySelector("button")!.disabled).toBe(true);
});

test("a folder harness keeps its card with its own hint and action", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <HostError
        message="Claude Code is not enabled."
        hint={null}
        action="Enable Claude Code"
        onRetry={() => undefined}
      />,
    );
  });
  expect(container.querySelector(".acpmux-host-error-card")).not.toBeNull();
  expect(buttons(container)).toEqual(["Enable Claude Code"]);
  expect(container.querySelectorAll("p")).toHaveLength(1);
});
