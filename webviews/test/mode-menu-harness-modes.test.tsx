// l10n-allow-file: test fixtures.
// l10n-allow-file: test fixtures.
// The mode menu lists the harness's OWN modes (Leo 2026-10-21, "WHY ARE YOU HALLUCINATING THINGS?"):
// Claude Code's Mode menu (Auto [Recommended], Manual, Accept edits, Plan, Bypass permissions, keys 1
// to 5) and Codex's approval choices (Ask for approval, Approve for me, Full access, each with its
// own icon), with their labels, descriptions and order. Never an invented
// "Normal" or a Claude "Full access". The mode button shows the mode's symbol and its label, with no
// pill at rest; the chosen row's check is the theme's lit accent (--agent-lit-glyph).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Mode = { id: string; name: string; description?: string };

function summary(harness: string, currentModeId: string, availableModes: Mode[]) {
  return {
    sessionId: `s-${harness}`,
    harness,
    family: harness,
    model: "default",
    turnCount: 0,
    modes: { currentModeId, availableModes },
  };
}

// Claude's five mode ids under acpmux's old invented names (Normal, Full access; acpmux reports
// Claude Code's own since #23777): the menu shows Claude Code's own labels whatever names arrive.
const CLAUDE_REPORTED: Mode[] = [
  { id: "default", name: "Normal" },
  { id: "plan", name: "Plan" },
  { id: "auto", name: "Auto" },
  { id: "acceptEdits", name: "Accept edits" },
  { id: "bypassPermissions", name: "Full access" },
];
// The Codex bridge's modes (cmux-codex-acp config.rs MODES) plus Codex's auto-review mode.
const CODEX_REPORTED: Mode[] = [
  { id: "ask", name: "Ask", description: "Asks before every command and every edit" },
  { id: "read-only", name: "Read Only", description: "Reads files; asks before any edit or command that needs more" },
  { id: "agent", name: "Agent", description: "Edits and runs commands in the workspace; asks to go outside it" },
  { id: "auto-review", name: "Auto review" },
  { id: "agent-full-access", name: "Agent (full access)", description: "Edits and runs anything without asking" },
];

async function render(snapshotSummary: ReturnType<typeof summary>) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary: snapshotSummary,
  } as unknown as Snapshot;
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <div className="acpmux-composer-bar" data-footer-look="plain">
          <ComposerPickers
            snapshot={snapshot}
            onModel={() => undefined}
            onMode={() => undefined}
            onEffort={() => undefined}
            onHarness={() => undefined}
            showPlan={false}
          />
        </div>
      </QueryClientProvider>,
    );
  });
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
}

const text = (node: Element | null | undefined) => (node?.textContent ?? "").trim();
function rows() {
  return [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")].map((row) => ({
    name: text(row.querySelector(".acpmux-menu-label")),
    description: text(row.querySelector(".acpmux-menu-description")),
    key: text(row.querySelector(".ui-menu-shortcut")),
    badge: text(row.querySelector(".acpmux-menu-badge")),
    icon: row.querySelector(".acpmux-access-item-icon svg")?.getAttribute("data-mode-icon") ?? "",
    checked: row.hasAttribute("data-checked") || row.getAttribute("aria-checked") === "true",
  }));
}
const heading = () => text(dom.window.document.querySelector(".acpmux-access-menu .acpmux-access-heading"));

test("a Claude chat's menu is Claude Code's own Mode menu, in its order, with its keys", async () => {
  await render(summary("claude", "bypassPermissions", CLAUDE_REPORTED));
  expect(heading()).toBe("");
  expect(rows().map(({ name, description, key, badge }) => ({ name, description, key, badge }))).toEqual([
    { name: "Auto", description: "Claude handles permission decisions", key: "1", badge: "Recommended" },
    { name: "Manual", description: "Always ask before making changes", key: "2", badge: "" },
    { name: "Accept edits", description: "Automatically accept all file edits", key: "3", badge: "" },
    { name: "Plan", description: "Create a plan before making changes", key: "4", badge: "" },
    { name: "Bypass permissions", description: "Accepts all permissions", key: "5", badge: "" },
  ]);
  expect(rows().find((row) => row.checked)?.name).toBe("Bypass permissions");
  const all = dom.window.document.body.textContent ?? "";
  expect(all).not.toContain("Normal");
  expect(all).not.toContain("Full access");
});

test("a Codex chat's menu is Codex's own approval menu, with its icons and descriptions", async () => {
  await render(summary("codex", "agent-full-access", CODEX_REPORTED));
  expect(heading()).toBe("");
  expect(rows().map(({ name, description, icon, key }) => ({ name, description, icon, key }))).toEqual([
    {
      name: "Ask for approval",
      description: "Always ask to edit external files and use the internet",
      icon: "hand",
      key: "",
    },
    {
      name: "Approve for me",
      description: "Only ask for actions detected as potentially unsafe",
      icon: "terminal-shield",
      key: "",
    },
    {
      name: "Full access",
      description: "Unrestricted access to the internet and any file on your computer",
      icon: "shield-alert",
      key: "",
    },
  ]);
  expect(rows().find((row) => row.checked)?.name).toBe("Full access");
  const all = dom.window.document.body.textContent ?? "";
  expect(all).not.toContain("Normal");
  expect(all).not.toContain("Read Only");
});

test("a Codex chat on today's bridge (no auto review) shows Codex's rows it reports", async () => {
  // The bridge's real four ids: ask and read-only are acpmux's policy modes, not Codex's menu.
  await render(
    summary(
      "codex",
      "agent",
      CODEX_REPORTED.filter((mode) => mode.id !== "auto-review"),
    ),
  );
  expect(heading()).toBe("");
  expect(rows().map(({ name, icon, checked }) => ({ name, icon, checked }))).toEqual([
    { name: "Ask for approval", icon: "hand", checked: true },
    { name: "Full access", icon: "shield-alert", checked: false },
  ]);
  expect(dom.window.document.body.textContent ?? "").not.toContain("Approve for me");
});

test("the mode button shows the mode's symbol and its label", async () => {
  await render(summary("codex", "agent-full-access", CODEX_REPORTED));
  const trigger = host.querySelector<HTMLElement>(".acpmux-access-trigger")!;
  const first = trigger.firstElementChild;
  expect(first?.tagName.toLowerCase()).toBe("svg");
  expect(first?.getAttribute("data-mode-icon")).toBe("shield-alert");
  expect(text(trigger.querySelector(".acpmux-mode-text"))).toBe("Full access");
});

const css = readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"),
  "utf8",
).replace(/\/\*[\s\S]*?\*\//g, "");

test("the plain footer keeps the mode's symbol beside its label and draws no pill at rest", () => {
  // No rule hides the access button's leading symbol in the plain footer any more.
  expect(css).not.toMatch(
    /data-footer-look="plain"\][^{]*\.acpmux-access-trigger > \.acpmux-icon:first-child\s*\{\s*display:\s*none/,
  );
  // At rest the plain footer's mode button has no fill and no ring.
  expect(css).toMatch(
    /\[data-footer-look="plain"\]\s*:is\(\.acpmux-model, \.acpmux-effort, \.acpmux-access\)\s*\.acpmux-picker-button:not\(:hover, :focus-visible, :active, \[aria-expanded="true"\], \[data-press-active\]\)\s*\{\s*background: none;\s*box-shadow: none;/,
  );
});

test("menu rows are tight and the chosen row's check is the theme accent", () => {
  const rule = (selector: string) => {
    const at = css.indexOf(`${selector} {`);
    expect(at).toBeGreaterThanOrEqual(0);
    return css.slice(at, css.indexOf("}", at));
  };
  // About 8 pt from the menu's edge to a row's text: the popup's 4 px and the row's 4 px.
  expect(rule(".ui-menu-item.acpmux-access-item")).toMatch(/padding: 5px 4px;/);
  expect(rule(".acpmux-access-item .ui-menu-check")).toMatch(
    /color: var\(--agent-lit-glyph, var\(--agent-accent, var\(--agent-text\)\)\);/,
  );
});
