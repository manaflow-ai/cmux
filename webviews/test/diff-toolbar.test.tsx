// DOM coverage for the diff toolbar: the source menu, the floating pill and its
// "..." menu (option wiring, unavailable rows, keyboard access), the jump-to-file
// palette and the branch picker against a fixture transport.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import type { Root } from "react-dom/client";
import { App } from "../src/App";
import { BranchBasePicker, type BranchPickerPayload } from "../src/BranchBasePicker";
import type { DiffTransport } from "../src/diff/transport";
import type { DiffItem } from "../src/diff-stream";
import { JumpToFilePalette, SourceMenu } from "../src/DiffToolbar";
import { createDiffViewerLabelResolver } from "../src/labels";
import { createDiffViewerStatus } from "../src/status";
import { sourceMenuModel, type SourceTarget } from "../src/toolbar-model";
import type { DiffSource } from "../src/diff/generated/protocol";
import { privateCreateRoot } from "./viewer-empty-dom";

let root: Root | null = null;
// React DOM picks how onChange reads text inputs when its module first evaluates, and bun shares
// one module cache across files and preloads. A private client copy evaluated inside the jsdom
// window always takes native `input` events, however the shared copy started.
let createRoot: typeof import("react-dom/client").createRoot | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, unknown>();
for (const key of [
  "window",
  "document",
  "navigator",
  "Element",
  "Node",
  "HTMLElement",
  "HTMLButtonElement",
  "HTMLStyleElement",
  "customElements",
  "fetch",
  "requestAnimationFrame",
  "cancelAnimationFrame",
]) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

afterEach(async () => {
  if (root) flushSync(() => root?.unmount());
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[key];
    else (globalThis as Record<string, unknown>)[key] = value;
  }
});

const label = createDiffViewerLabelResolver(undefined);

function setup(): Document {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", { url: "http://127.0.0.1/diff" });
  const g = globalThis as Record<string, unknown>;
  g.window = dom.window;
  g.document = dom.window.document;
  g.navigator = dom.window.navigator;
  g.Element = dom.window.Element;
  g.Node = dom.window.Node;
  g.HTMLElement = dom.window.HTMLElement;
  g.HTMLButtonElement = dom.window.HTMLButtonElement;
  g.HTMLStyleElement = dom.window.HTMLStyleElement;
  g.customElements = dom.window.customElements;
  g.fetch = () => {
    throw new Error("unexpected fetch");
  };
  g.requestAnimationFrame = (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0);
  g.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  createRoot ??= privateCreateRoot();
  return dom.window.document;
}

function render(element: React.ReactNode): void {
  root = createRoot!(dom!.window.document.getElementById("root")!);
  flushSync(() => root?.render(element));
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const timeoutAt = Date.now() + 1000;
  while (!predicate()) {
    if (Date.now() > timeoutAt) throw new Error("Timed out waiting for toolbar assertion");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

function key(target: Element, keyName: string): void {
  target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: keyName }));
}

function type(input: HTMLInputElement, value: string): void {
  const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
}

function renderStatusApp() {
  render(
    <App
      config={{ payload: { statusMessage: "Rendered diff", title: "Diff" } }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );
}

const option = (doc: Document, id: string) => doc.querySelector<HTMLButtonElement>(`[data-option="${id}"]`);

test("the pill shows every button with a tooltip and the options menu toggles Word diffs", async () => {
  const doc = setup();
  renderStatusApp();
  const pill = doc.querySelector(".diff-pill");
  expect(pill?.getAttribute("role")).toBe("toolbar");
  const buttons = Array.from(doc.querySelectorAll<HTMLButtonElement>(".diff-pill-button"));
  expect(buttons.map((button) => button.dataset.tooltip)).toEqual([
    "Options",
    "Find in diff",
    "Refresh",
    "Word wrap",
    "Collapse all diffs",
    doc.documentElement.dataset.layout === "split" ? "Switch to unified diff" : "Switch to split diff",
    "Hide files",
  ]);
  // One tab stop; the rest are reached with the arrow keys.
  expect(buttons.map((button) => button.tabIndex)).toEqual([0, -1, -1, -1, -1, -1, -1]);

  doc.getElementById("options-button")?.click();
  await waitFor(() => Boolean(option(doc, "word-diffs")));
  expect(option(doc, "word-diffs")?.getAttribute("aria-checked")).toBe("false");
  option(doc, "word-diffs")?.click();
  await waitFor(() => option(doc, "word-diffs")?.getAttribute("aria-checked") === "true");
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.diffViewer.options") ?? "{}").wordDiffs).toBe(true);
});

test("options without an implementation are marked unavailable and do nothing", async () => {
  const doc = setup();
  renderStatusApp();
  doc.getElementById("options-button")?.click();
  await waitFor(() => Boolean(option(doc, "hide-whitespace")));
  for (const id of ["load-full-files", "rich-preview", "hide-whitespace", "hide-imports"]) {
    const row = option(doc, id);
    expect(row?.getAttribute("aria-disabled")).toBe("true");
    expect(row?.title).toBe("Not available yet: cmux does not support this option");
    row?.click();
    expect(row?.getAttribute("aria-checked")).toBe("false");
  }
  expect(dom!.window.localStorage.getItem("cmux.diffViewer.options")).toBeNull();
  expect(option(doc, "copy-git-apply")?.getAttribute("aria-disabled")).toBeNull();
});

test("pill buttons drive word wrap, collapse and layout, and the keyboard moves along the pill", async () => {
  const doc = setup();
  renderStatusApp();
  doc.getElementById("wrap-toggle")?.click();
  await waitFor(() => doc.documentElement.dataset.wordWrap === "true");
  expect(doc.getElementById("wrap-toggle")?.getAttribute("aria-pressed")).toBe("true");
  doc.getElementById("expand-toggle")?.click();
  await waitFor(() => doc.getElementById("expand-toggle")?.dataset.tooltip === "Expand all diffs");
  const before = doc.documentElement.dataset.layout;
  const after = before === "split" ? "unified" : "split";
  doc.getElementById("layout-toggle")?.click();
  await waitFor(() => doc.documentElement.dataset.layout === after);
  expect(doc.getElementById("layout-toggle")?.getAttribute("aria-label")).toBe(
    after === "split" ? "Switch to unified diff" : "Switch to split diff",
  );

  const options = doc.getElementById("options-button")!;
  options.focus();
  key(options, "ArrowRight");
  await waitFor(() => doc.activeElement?.id === "find-toggle");
  key(doc.activeElement!, "End");
  await waitFor(() => doc.activeElement?.id === "files-toggle");
  expect(doc.getElementById("files-toggle")?.tabIndex).toBe(0);
});

test("the options menu takes focus, moves with arrows and Escape returns to its button", async () => {
  const doc = setup();
  renderStatusApp();
  doc.getElementById("options-button")?.click();
  await waitFor(() => doc.activeElement?.getAttribute("data-option") === "word-diffs");
  key(doc.activeElement!, "ArrowDown");
  await waitFor(() => doc.activeElement?.getAttribute("data-option") === "hide-whitespace");
  key(doc.activeElement!, "ArrowUp");
  key(doc.activeElement!, "ArrowUp");
  await waitFor(() => doc.activeElement !== null && doc.activeElement.closest("#options-menu") != null);
  key(doc.activeElement!, "Escape");
  await waitFor(() => doc.getElementById("options-menu") == null);
  expect(doc.activeElement?.id).toBe("options-button");
});

function renderSourceMenu(activeSource: DiffSource, onSelect: (target: SourceTarget) => void) {
  const model = sourceMenuModel({
    sourceOptions: undefined,
    repoRoot: "/tmp/repo",
    activeSource,
    typedTransport: true,
    isValidSource: (value): value is DiffSource => typeof value === "object" && value != null,
  });
  render(<SourceMenu additions={130} deletions={273} label={label} model={model} onSelect={onSelect} />);
}

test("the source pill shows the source and totals, and its menu selects a source", async () => {
  const doc = setup();
  const chosen: SourceTarget[] = [];
  renderSourceMenu({ kind: "branch", repoRoot: "/tmp/repo", baseRef: "origin/main" }, (target) => chosen.push(target));
  expect(doc.querySelector(".source-pill-label")?.textContent).toBe("Branch");
  expect(doc.querySelector(".source-pill-stats")?.textContent).toBe("+130-273");

  doc.getElementById("source-menu-button")?.click();
  await waitFor(() => Boolean(doc.querySelector(".source-menu")));
  const rows = Array.from(doc.querySelectorAll<HTMLButtonElement>(".source-menu [data-source-id]"));
  expect(rows.map((row) => [row.textContent, row.getAttribute("aria-checked")])).toEqual([
    ["Last Turn", "false"],
    ["Uncommitted", "false"],
    ["Unstaged", "false"],
    ["Staged", "false"],
    ["Branch", "true"],
  ]);
  // Last Turn needs a host option; choosing it does nothing.
  rows[0]?.click();
  expect(chosen).toEqual([]);
  expect(rows[0]?.getAttribute("aria-disabled")).toBe("true");
  doc.querySelector<HTMLButtonElement>('[data-source-id="uncommitted"]')?.click();
  expect(chosen).toEqual([{ kind: "session", source: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "HEAD" } }]);
  await waitFor(() => doc.querySelector(".source-menu") == null);
});

test("Committed opens its submenu from the keyboard and lists no commits without a host", async () => {
  const doc = setup();
  renderSourceMenu({ kind: "unstaged", repoRoot: "/tmp/repo" }, () => {});
  expect(doc.querySelector(".source-pill-label")?.textContent).toBe("Unstaged");
  const button = doc.getElementById("source-menu-button")!;
  key(button, "ArrowDown");
  // Focus lands on the first row that can be chosen (Last Turn needs a host).
  await waitFor(() => doc.activeElement?.getAttribute("data-source-id") === "uncommitted");
  const committed = Array.from(doc.querySelectorAll<HTMLButtonElement>(".source-menu [aria-haspopup='menu']"))[0]!;
  committed.focus();
  key(committed, "ArrowRight");
  await waitFor(() => Boolean(doc.querySelector(".toolbar-submenu")));
  expect(doc.querySelector(".toolbar-submenu")?.textContent).toBe("No commits to show");
});

test("jump to file filters by name and Enter jumps to the highlighted file", async () => {
  const doc = setup();
  const jumped: string[] = [];
  const items = ["plans/cmux-tui-change-log.md", "CLAUDE.md", "scripts/cmux-home-name-workspace.sh"].map(
    (name) => ({ id: name, fileDiff: { name, hunks: [] } }) as DiffItem,
  );
  render(<JumpToFilePalette items={items} label={label} onJump={(id) => jumped.push(id)} />);
  doc.getElementById("jump-to-file-button")?.click();
  await waitFor(() => Boolean(doc.querySelector(".jump-palette-input")));
  const rowText = () =>
    Array.from(doc.querySelectorAll(".jump-palette-row")).map(
      (row) =>
        `${row.querySelector(".jump-palette-name")?.textContent}|${row.querySelector(".jump-palette-dir")?.textContent ?? ""}`,
    );
  expect(rowText()).toEqual(["CLAUDE.md|", "cmux-home-name-workspace.sh|scripts", "cmux-tui-change-log.md|plans"]);
  const input = doc.querySelector<HTMLInputElement>(".jump-palette-input")!;
  expect(doc.activeElement).toBe(input);
  type(input, "tui");
  await waitFor(() => rowText().length === 1);
  key(input, "Enter");
  expect(jumped).toEqual(["plans/cmux-tui-change-log.md"]);
  await waitFor(() => doc.querySelector(".jump-palette") == null);
});

// The fixture stands in for `cmux __diff-viewer-refs`, which the dev sidecar
// cannot run yet: the branchList reply has the shape the sidecar forwards.
function fixtureTransport(reply: "ok" | "fail"): DiffTransport & { requests: any[] } {
  const requests: any[] = [];
  return {
    requests,
    async request(command: any) {
      requests.push(command);
      if (reply === "fail") throw new Error("Could not load branches");
      return {
        type: "branches",
        value: {
          groups: [
            {
              id: "branches",
              label: "Branches",
              rows: [
                { ref: "origin/main", label: "origin/main" },
                { ref: "feat-source-depot-lru-eviction", label: "feat-source-depot-lru-eviction" },
                { ref: "feat-hq-close-old-apps", label: "feat-hq-close-old-apps" },
              ],
            },
          ],
        },
      } as any;
    },
    subscribe: () => () => {},
    openResource: () => Promise.reject(new Error("unused")),
    close: () => {},
  };
}

const typedPicker: BranchPickerPayload = {
  repoRoot: "/tmp/repo",
  capabilityToken: "0123456789abcdef",
  headRef: "feat/better-404",
  currentRef: "origin/main",
  currentReason: "",
  confidence: "high",
  aheadBehind: null,
  refsURL: "typed://branch-list",
  regenerateURLTemplate: "typed://branch-change/{ref}",
};

test("branch picker lists fixture branches with icons, a check on the base, and selects one", async () => {
  const doc = setup();
  const transport = fixtureTransport("ok");
  const selected: string[] = [];
  render(
    <BranchBasePicker
      label={label}
      onNavigate={() => {}}
      onSelectBranchBase={(ref) => selected.push(ref)}
      picker={typedPicker}
      transport={transport}
    />,
  );
  expect(doc.querySelector(".base-picker-head")?.textContent).toBe("feat/better-404");
  expect(doc.querySelector(".base-picker-ref")?.textContent).toBe("origin/main");
  doc.getElementById("base-picker-button")?.click();
  await waitFor(() => doc.querySelectorAll(".base-picker-row").length === 3);
  expect(transport.requests[0]).toEqual({
    method: "branchList",
    params: { repoRoot: "/tmp/repo", capabilityToken: "0123456789abcdef", selectedBase: "origin/main" },
  });
  expect(doc.querySelector<HTMLInputElement>(".base-picker-input")?.placeholder).toBe("Search branches");
  expect(doc.querySelector(".base-picker-group-header")?.textContent).toBe("Branches");
  const rows = Array.from(doc.querySelectorAll(".base-picker-row"));
  expect(rows.every((row) => row.querySelector(".base-picker-row-icon svg") != null)).toBe(true);
  expect(rows.map((row) => row.querySelector(".base-picker-row-check svg") != null)).toEqual([true, false, false]);
  expect(rows[0]?.getAttribute("aria-current")).toBe("true");
  rows[2]?.dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true }));
  expect(selected).toEqual(["feat-hq-close-old-apps"]);
});

test("branch picker still takes a typed ref when the branch list cannot load", async () => {
  const doc = setup();
  const selected: string[] = [];
  render(
    <BranchBasePicker
      label={label}
      onNavigate={() => {}}
      onSelectBranchBase={(ref) => selected.push(ref)}
      picker={typedPicker}
      transport={fixtureTransport("fail")}
    />,
  );
  doc.getElementById("base-picker-button")?.click();
  await waitFor(() => doc.querySelector(".base-picker-status-error")?.textContent === "Could not load branches.");
  const input = doc.querySelector<HTMLInputElement>(".base-picker-input")!;
  type(input, "HEAD~3");
  await waitFor(() => doc.querySelector(".base-picker-row-primary")?.textContent === 'Use "HEAD~3" (raw)');
  expect(doc.querySelector(".base-picker-status-error")).toBeTruthy();
  key(input, "Enter");
  // The typed ref is offered as a raw row, so the picker works without a branch list.
  expect(selected).toEqual(["HEAD~3"]);
});
