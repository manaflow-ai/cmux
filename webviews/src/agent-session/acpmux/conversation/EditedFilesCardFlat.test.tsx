// l10n-allow-file: test fixtures.
// The edited-files card is the one container for a diff it opens (#56442): the diff's header (name,
// counts, Wrap, copy, Open in Changes) and lines sit directly on the card, with no second ring,
// corner, fill or padding inside it. An edit call's own diff in the transcript keeps its box.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { setChipHost } from "../chips/host";
import { EditedFilesCard } from "./EditedFilesCard";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  setChipHost(undefined);
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

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // An opened diff loads @pierre/diffs, whose web component registers itself where there is an
    // HTMLElement, follows the theme attribute and subscribes to a layout observer jsdom lacks.
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // Pierre's element reads its DOM constructors from the globals when it draws; each goes in teardown.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      if (!saved.has(key)) saved.set(key, undefined);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

let ids = 0;
const write = (path: string, newText: string, oldText?: string): AcpmuxActivity => {
  const id = `tool-${++ids}`;
  return {
    kind: "tool",
    text: `Edit ${path}`,
    tool: {
      id,
      title: `Edit ${path}`,
      kind: "edit",
      status: "completed",
      locations: [{ path }],
      diffs: [{ path, oldText, newText }],
    },
  };
};
const turn = (items: AcpmuxActivity[]): AcpmuxRow =>
  ({ id: `edits-${++ids}`, version: 1, at: 0, kind: "activity", ended: true, items }) as AcpmuxRow;

import { readFileSync } from "node:fs";

const css = (name: string) => readFileSync(new URL(name, import.meta.url), "utf8");
const rule = (sheet: string, selector: string) => {
  const at = sheet.indexOf(`${selector} {`);
  return at < 0 ? "" : sheet.slice(at, sheet.indexOf("}", at));
};
const card = (row: AcpmuxRow) => <EditedFilesCard row={row} onOpenDiff={() => {}} />;
const RETRY = "/home/dev/atlas/src/retry.ts";

test("a card for one file opens its diff flat on the card, not in a second box", async () => {
  const container = await render(card(turn([write(RETRY, "export const tries = 3;\n", "export const tries = 1;\n")])));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-edited-toggle")!.click());
  const diff = container.querySelector(".acpmux-edited-stack .cv-edit-diff");
  expect(diff?.hasAttribute("data-flat")).toBe(true);
  // Its header and actions (Wrap, copy, Open in Changes) stay, now on the card itself.
  for (const action of [".cv-edit-diff__wrap", ".cv-edit-diff__copy", ".acpmux-edited-open"])
    expect(diff?.querySelector(`.cv-edit-diff__header ${action}`)).not.toBeNull();
});

test("a card for several files stacks every file's diff flat in the one box", async () => {
  const container = await render(
    card(
      turn([
        write(RETRY, "export const tries = 3;\n", "export const tries = 1;\n"),
        write("/home/dev/atlas/src/wait.ts", "export const wait = 50;\n", "export const wait = 10;\n"),
      ]),
    ),
  );
  const toggle = container.querySelector<HTMLButtonElement>(".acpmux-edited-toggle");
  if (toggle?.getAttribute("aria-expanded") === "false") await act(async () => toggle.click());
  const diffs = [...container.querySelectorAll(".acpmux-edited-stack .acpmux-edited-section > .cv-edit-diff")];
  expect(diffs).toHaveLength(2);
  for (const diff of diffs) expect(diff.hasAttribute("data-flat")).toBe(true);
});

test("a flat diff draws no ring, corner, fill or inset of its own; an edit call's diff keeps its box", () => {
  const conversation = css("./conversation.css");
  const flat = rule(conversation, ".cv-edit-diff[data-flat]");
  for (const declaration of ["margin: 0", "border-radius: 0", "background: transparent", "box-shadow: none"])
    expect(flat).toContain(declaration);
  expect(rule(conversation, ".cv-edit-diff")).toContain("box-shadow: inset 0 0 0 1px var(--cv-codeblock-ring)");
  const edited = css("./EditedFilesCard.css");
  // The card no longer pads the diff in from its edges.
  expect(rule(edited, ".acpmux-edited .acpmux-edited-diff")).toBe("");
  expect(edited).not.toMatch(/\.acpmux-edited-diff > \.cv-edit-diff \{[^}]*margin/);
});
