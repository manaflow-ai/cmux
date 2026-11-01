// l10n-allow-file: test fixtures.
// A transcript activity row that folds (subagents/DisclosureRow.tsx on the shared
// TranscriptActivityRowShell, #29754) toggles from a click anywhere on its line, edge to edge
// (headerToggle.ts). That wide target is the pointer's only. The keyboard and screen reader control
// is the row's own toggle <button>: it takes Tab focus, says its state with aria-expanded, and
// Return or Space on it (a click with detail 0) opens and closes the row. The line itself is not a
// control: `presentation`, no tab stop, no stand-in key handler (cmux-ad 2026-11-01 found an empty
// onKeyDown and a lint silencer standing in for one).
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { DisclosureRow } = await import("../src/agent-session/acpmux/subagents/DisclosureRow");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Row({ onOpen }: { onOpen?: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <DisclosureRow
      label="Subagent tests finished"
      toggleLabel="Show tests"
      onOpen={onOpen}
      open={open}
      onOpenChange={setOpen}
      animates={() => false}
    >
      <p>The whole report.</p>
    </DisclosureRow>
  );
}

async function render(onOpen?: () => void) {
  root = createRoot(host);
  await act(async () => root!.render(<Row onOpen={onOpen} />));
  const line = host.querySelector<HTMLElement>(".cv-disclosure__line")!;
  const toggle = line.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!;
  return { line, toggle };
}

/// What a browser sends a focused <button> for Return or Space: a click with detail 0.
async function pressKey(button: HTMLButtonElement) {
  button.focus();
  expect(dom.window.document.activeElement).toBe(button);
  await act(async () => {
    button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 0 }));
  });
}

for (const [name, onOpen] of [
  ["the line's toggle", undefined],
  ["the chevron of a line that opens a chat", () => undefined],
] as const)
  test(`${name} is a real button that opens and closes the row from the keyboard`, async () => {
    const { line, toggle } = await render(onOpen);
    // The line is not a control: no role a screen reader names, no tab stop.
    expect(line.getAttribute("role")).toBe("presentation");
    expect(line.hasAttribute("tabindex")).toBe(false);
    // The toggle is the control: a native button in the tab order with its state.
    expect(toggle.tagName).toBe("BUTTON");
    expect(toggle.getAttribute("type")).toBe("button");
    expect(toggle.tabIndex).toBe(0);
    expect(toggle.getAttribute("aria-label")).toBe("Show tests");
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    await pressKey(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(host.textContent).toContain("The whole report.");
    await pressKey(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
  });

test("a pointer click on the line's bare space toggles the same row", async () => {
  const { line, toggle } = await render();
  await act(async () => {
    line.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, button: 0, detail: 1 }));
  });
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
});
