// The environment picker's Cloud row (Labs, cloudRun.ts): picking it makes Cloud where the new
// chat runs and hands the keyboard back to the prompt, on the first pick as on a repeat, so Return
// sends the draft. A machine picked after it makes the chat a chat here again.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { EnvironmentPicker } from "./EnvironmentPicker";
import type { RunMode } from "./sandboxRun";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

/// A new chat's composer: its prompt, and the picker with Run as rows the test can read back.
function Composer({ modes, picks, start }: { modes: RunMode[]; picks: string[]; start: RunMode }) {
  const [mode, setMode] = useState<RunMode>(start);
  return (
    <div className="nt-composer">
      <textarea aria-label="prompt" />
      <EnvironmentPicker
        label="Environment"
        menu="Computer"
        value="This Mac"
        face={<span>{mode === "cloud" ? "Cloud" : "This Mac"}</span>}
        environments={[
          { id: "local", label: "This Mac", kind: "local", connected: true },
          { id: "gpu-box", label: "gpu-box", kind: "ssh", connected: true },
        ]}
        current="local"
        onPick={(id) => picks.push(id)}
        runMode={{
          mode,
          onMode: (next) => {
            modes.push(next);
            setMode(next);
          },
        }}
      />
    </div>
  );
}

async function render(start: RunMode) {
  const container = installDom();
  const modes: RunMode[] = [];
  const picks: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<Composer modes={modes} picks={picks} start={start} />);
  });
  return { container, modes, picks };
}

async function open(container: HTMLElement) {
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  await settle();
}

async function choose(selector: string) {
  const row = document.querySelector<HTMLElement>(`.acpmux-env-popover ${selector}`);
  expect(row).not.toBeNull();
  const option = row!.closest<HTMLElement>('[role="option"]') ?? row!;
  await act(async () => option.click());
  await settle();
}

test("the Cloud row heads the Cloud section and picking it makes Cloud the mode and focuses the prompt", async () => {
  const { container, modes } = await render("persistent");
  await open(container);
  await choose('[data-mode="cloud"]');
  expect(modes).toEqual(["cloud"]);
  // The first pick too: the popover returns no focus, so Return would not reach the prompt.
  expect(document.activeElement).toBe(container.querySelector("textarea"));
  expect(container.querySelector(".acpmux-location-button")?.textContent).toBe("Cloud");
});

test("picking Cloud again changes nothing and still focuses the prompt", async () => {
  const { container, modes } = await render("cloud");
  await open(container);
  expect(document.querySelector('.acpmux-env-popover [data-mode="cloud"][data-current]')).not.toBeNull();
  await choose('[data-mode="cloud"]');
  expect(modes).toEqual([]);
  expect(document.activeElement).toBe(container.querySelector("textarea"));
});

test("a machine picked while Cloud is the mode makes the chat a chat here again", async () => {
  const { container, modes, picks } = await render("cloud");
  await open(container);
  await choose('[data-kind="ssh"]');
  expect(modes).toEqual(["persistent"]);
  expect(picks).toEqual(["gpu-box"]);
});
