// A chat whose agent did not start says what happened in plain words and what to do, never the
// agent's raw words as the sentence (Lawrence, 2026-11-07: "we need better error messages in the
// chat ui itself"). The raw words stay one click away under Details, with Copy error. A refusal
// cmux-tui wrote for people (a coded one with its own way out) keeps its sentence as it is.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SwitchNotice } from "./SwitchNotice";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let copied: string[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  copied = [];
  Object.defineProperty(dom.window.navigator, "clipboard", {
    value: { writeText: async (text: string) => void copied.push(text) },
  });
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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(container: HTMLElement, error: string, ran: string[], code?: string, installs = true) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <SwitchNotice
        switching={{ harness: "claude", name: "Claude Code", phase: "failed", error, ...(code && { code }) }}
        onRetry={() => ran.push("retry")}
        onAction={(action) => ran.push(action)}
        installs={installs}
      />,
    );
  });
}

const sentence = (container: HTMLElement) =>
  container.querySelector(".acpmux-host-error-message")?.textContent?.trim() ?? "";
const details = (container: HTMLElement) => container.querySelector("details");
const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")].map((b) => b.textContent);
async function press(container: HTMLElement, name: string) {
  const button = [...container.querySelectorAll("button")].find((b) => b.textContent === name);
  if (!button) throw new Error(`no ${name} in ${buttons(container).join(", ")}`);
  await act(async () => button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true })));
}

test("an agent that is not installed says so and offers Install, the raw words under Details", async () => {
  const container = installDom();
  const ran: string[] = [];
  const raw = "spawn claude-agent-acp: No such file or directory (os error 2)";
  await render(container, raw, ran);
  expect(sentence(container)).toBe("Claude Code isn't installed on this machine.");
  expect(sentence(container)).not.toContain("os error");
  expect(details(container)?.textContent).toContain(raw);
  await press(container, "Install");
  await press(container, "Retry");
  expect(ran).toEqual(["install", "retry"]);
});

test("a chat on another machine says the agent is not installed there, with no Install that would run here", async () => {
  const container = installDom();
  await render(container, "spawn codex-acp: No such file or directory (os error 2)", [], undefined, false);
  expect(sentence(container)).toBe("Claude Code isn't installed on this machine.");
  expect(buttons(container)).not.toContain("Install");
  expect(buttons(container)).toContain("Retry");
});

test("a missing folder is not a missing agent: no Install", async () => {
  const container = installDom();
  await render(container, "spawn claude-agent-acp: No such file or directory (os error 2): cwd /work/gone", []);
  expect(sentence(container)).toBe("Claude Code couldn’t start.");
  expect(buttons(container)).not.toContain("Install");
});

test("a start that could not reach its server says that, not the socket error", async () => {
  const container = installDom();
  const raw = "connect ECONNREFUSED 127.0.0.1:443";
  await render(container, raw, []);
  expect(sentence(container)).toBe("Claude Code could not reach its server.");
  expect(details(container)?.textContent).toContain(raw);
});

test("an unknown start failure still reads as a sentence, and Copy error copies the raw words", async () => {
  const container = installDom();
  const raw = "acp handshake: unexpected frame 0x1f in initialize";
  await render(container, raw, []);
  expect(sentence(container)).toBe("Claude Code couldn’t start.");
  await press(container, "Copy error");
  expect(copied).toEqual([raw]);
  expect(buttons(container)).toContain("Copied");
});

test("a refusal written as plain sentences keeps them, as before", async () => {
  const container = installDom();
  const text = "build-box did not start the agent in time. Try again.";
  await render(container, text, []);
  expect(sentence(container)).toBe(`Couldn't start Claude Code: ${text}`);
  expect(details(container)).toBeNull();
});

test("acpmux's own not-installed sentence still offers Install", async () => {
  const container = installDom();
  await render(container, "Claude Code is not installed on this machine.", []);
  expect(sentence(container)).toBe("Claude Code isn't installed on this machine.");
  expect(buttons(container)).toContain("Install");
});

test("a coded refusal written for people keeps its own sentence and has no Details", async () => {
  const container = installDom();
  const text = "build-box has no work folder to start in. Use Choose folder to pick one there.";
  await render(container, text, [], "app.folder_needed");
  expect(sentence(container)).toBe(`Couldn't start Claude Code: ${text}`);
  expect(details(container)).toBeNull();
});
