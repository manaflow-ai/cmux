// l10n-allow-file: sample chat names in fixtures.
// The banner over a chat the Chief or another chat's agent is driving (ManagedBanner.tsx). It says
// what that means for the person, never "managing this chat" (Leo, 2026-11-03: "what does 'managing
// this chat' even mean?"), and its button says what it does: Hide. The button must carry a visible,
// accessible label: #30765 painted it as a solid pill whose text colour was --agent-page-bg, which
// is transparent in the agent pane, so the label never showed (Leo, 2026-11-01: "this needs to be a
// better button tell the coordinator").
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { ManagedBanner } from "./ManagedBanner";

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

test("the line says the agent is sending messages here, and Hide is a button with a readable label", async () => {
  const container = installDom();
  let hidden = 0;
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <ManagedBanner
        manager={{ kind: "agent", name: "claude-sr2-coord", sessionId: "s-coord" }}
        onHide={() => hidden++}
        onOpenManager={() => undefined}
      />,
    ),
  );
  expect(container.textContent).toContain(
    "claude-sr2-coord is sending messages here. What you type still sends as you.",
  );
  expect(container.textContent).not.toContain("managing this chat");
  expect(container.textContent).not.toContain("Take over");
  const button = container.querySelector<HTMLButtonElement>("button.acpmux-managed-take-over");
  expect(button).not.toBeNull();
  // Its accessible name is its text: no empty pill, no icon-only control.
  expect(button!.textContent?.trim()).toBe("Hide");
  expect(button!.getAttribute("aria-label") ?? button!.textContent?.trim()).toBe("Hide");
  await act(async () => button!.click());
  expect(hidden).toBe(1);
});

test("the Hide label is painted in the transcript's text colour on a quiet button, never a transparent token", () => {
  const css = readFileSync(new URL("./managedBanner.css", import.meta.url), "utf8");
  const rule = css.match(/\.acpmux-managed-take-over\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).not.toBe("");
  // --agent-page-bg is transparent in the agent pane (shared/styles.css): as a text colour it hides
  // the label, and as the fill of a solid --agent-text block it made the oversized blank pill.
  expect(rule).not.toMatch(/(^|;)color:var\(--agent-page-bg\)/);
  expect(rule).toMatch(/(^|;)color:var\(--agent-text\)/);
  expect(rule).not.toMatch(/background:var\(--agent-text\)/);
  expect(rule).toMatch(/border:1px solid var\(--agent-border\)/);
});

test("the line sits on a glass capsule with readable text, so a background image never shows through bare", () => {
  const css = readFileSync(new URL("./managedBanner.css", import.meta.url), "utf8");
  const rule = css.match(/\.acpmux-managed-banner\{([^}]*)\}/)?.[1] ?? "";
  // #32745: muted text straight on the pane was unreadable over a background image.
  // The tint is the opaque composer surface at 70%, never a see-through token: over art the page
  // colour is alpha 0, which left --acpmux-composer-bg near clear.
  expect(rule).toMatch(
    /background:color-mix\(in srgb,var\(--acpmux-composer-solid,var\(--surface-popup\)\) 70%,transparent\)/,
  );
  expect(rule).not.toMatch(/--acpmux-composer-bg/);
  // The capsule takes the entry animation; the row must not, or the blur loses the art meanwhile.
  expect(rule).toMatch(/animation:ui-enter/);
  expect(css).toMatch(/\.acpmux-dock > div\.acpmux-managed-row\{animation:none\}/);
  expect(rule).toMatch(/backdrop-filter:blur\(/);
  expect(rule).not.toMatch(/(^|;)color:var\(--agent-muted\)/);
  // Reduced transparency swaps the glass for an opaque surface.
  expect(css).toMatch(/:root\[data-reduce-transparency\] \.acpmux-managed-banner\{background:var\(--surface-popup\)/);
});
