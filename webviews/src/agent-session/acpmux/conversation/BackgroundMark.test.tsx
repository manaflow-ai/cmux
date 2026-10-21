// l10n-allow-file: test fixture commands, not shipped UI.
// A shell call that went on in the background shows how it stands on its own "Ran" row, in a "Ran
// N commands" group (CommandRow) or alone (ToolRow): the running mark while it runs there, then a
// check with its time, "Failed" or "Stopped". A background task's end whose call is not in the
// transcript is one line naming the command in a few words, never the raw `export PATH=…` text
// (Leo 2026-10-20).
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxActivity, AcpmuxBackgroundState } from "../model";
import { BackgroundTaskNote } from "./BackgroundTaskNote";
import { CommandRow } from "./CommandRow";
import { ToolRow } from "./ToolRow";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
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
    localStorage: dom.window.localStorage,
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

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const STARTED = Date.UTC(2026, 9, 20, 9, 0, 0);
const call = (background?: AcpmuxBackgroundState): AcpmuxActivity => ({
  kind: "tool",
  text: "npm run dev",
  tool: {
    id: "bg1",
    title: "npm run dev",
    kind: "execute",
    status: "completed",
    command: "npm run dev",
    startedAt: STARTED,
    // The launch returned at once; the shell ran on.
    endedAt: STARTED + 200,
    ...(background ? { background } : {}),
  },
});

for (const [name, Row] of [
  ["CommandRow", CommandRow],
  ["ToolRow", ToolRow],
] as const) {
  test(`${name}: running in the background shows the running mark and no time`, async () => {
    const container = await render(<Row item={call({ state: "running" })} />);
    const mark = container.querySelector(".cv-command__bg-state")!;
    expect(mark.getAttribute("title")).toBe(translate("tools.background.running"));
    expect(mark.textContent).toBe(translate("tools.background.running"));
    expect(mark.querySelector(".cv-spinner")).not.toBeNull();
    expect(container.querySelector(".cv-command__ok")).toBeNull();
    expect(container.querySelector(".cv-command__time")).toBeNull();
  });

  test(`${name}: finished in the background is a check with the shell's whole run time`, async () => {
    const container = await render(<Row item={call({ state: "completed", endedAt: STARTED + 6_100 })} />);
    expect(container.querySelector(".cv-command__bg-state")).toBeNull();
    expect(container.querySelector(".cv-command__ok")).not.toBeNull();
    // Its time runs to the shell's end, not the launch's 200ms.
    expect(container.querySelector(".cv-command__time")!.textContent).toBe(translate("duration.s", { n: "6.1" }));
  });

  test(`${name}: failed and stopped say so, a stop with the agent's reason on hover`, async () => {
    const failed = await render(<Row item={call({ state: "failed", endedAt: STARTED + 1_000 })} />);
    expect(failed.querySelector(".cv-command__failed")!.textContent).toBe(translate("tools.failed"));
    await act(async () => root!.unmount());
    root = undefined;
    const stopped = await render(
      <Row item={call({ state: "stopped", reason: "Stopped by the agent", endedAt: STARTED + 1_000 })} />,
    );
    const label = stopped.querySelector(".cv-command__stopped")!;
    expect(label.textContent).toBe(translate("bgTask.state.stopped"));
    expect(label.getAttribute("title")).toBe("Stopped by the agent");
  });
}

test("a command that never went to the background draws as before", async () => {
  const container = await render(<ToolRow item={call()} />);
  expect(container.querySelector(".cv-tool__meta")).toBeNull();
});

test("a background task's end without its call names the command in a few words", async () => {
  const command =
    'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; B=~/Projects/leo-workspace; cmux browser open https://example.com';
  const container = await render(<BackgroundTaskNote task={{ toolCallId: "bg9", command, state: "completed" }} />);
  const note = container.querySelector(".cv-bgtask")!;
  expect(note.textContent).toBe(translate("bgTask.completed", { command: "cmux browser open https://example.com" }));
  expect(note.textContent).not.toContain("export PATH");
  // The whole command is still there on hover.
  expect(note.getAttribute("title")).toBe(command);
});
