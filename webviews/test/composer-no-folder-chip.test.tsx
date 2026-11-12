// Leo, 2026-11-09, on a new chat's strip reading "Choose folder ⌄  Cloud ⌄": "We need to be able to
// have it so, like, this no folder selected should be, like, good as well." A chat with no folder
// starts in a folder of its own on every target, so the empty folder chip reads No folder in the
// same weight as a picked folder: never a dimmed "Choose folder" prompt. The menu keeps Add
// folder… as an optional row. Gallery: agent-pane.no-folder-chip. Detector: the source scan below
// fails if the chip's face goes back to the Choose folder placeholder.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
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
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const base = {
  sessions: [],
  projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
  environments: true,
  localName: "studio-mac",
  peers: ["gpu-box"],
  peerKinds: { "gpu-box": "ssh" as const },
  peerConnected: { "gpu-box": true },
  cloudSignedIn: true,
  stripLayout: "where-machine" as const,
  runMode: { mode: "persistent" as const, onMode: () => undefined },
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onConnect: () => undefined,
};

const TARGETS = {
  "This Mac": base,
  Cloud: { ...base, runMode: { mode: "cloud" as const, onMode: () => undefined } },
  "another machine": { ...base, summary: { sessionId: "", harness: "claude", host: "gpu-box", peer: "gpu-box" } },
};

async function folderChip(props: Record<string, unknown>) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  root = createRoot(host);
  await act(async () => root!.render(<ComposerContext {...(props as React.ComponentProps<typeof ComposerContext>)} />));
  const chip = host.querySelector<HTMLElement>(`.acpmux-location-leading [aria-label="${t("composer.folder")}"]`);
  expect(chip, "the folder chip").toBeTruthy();
  return chip!;
}

for (const [target, props] of Object.entries(TARGETS))
  test(`with no folder on ${target}, the chip reads No folder as a settled choice`, async () => {
    const chip = await folderChip(props);
    const label = chip.querySelector(".acpmux-location-label");
    expect(label?.textContent).toBe(t("project.noFolder"));
    expect(chip.textContent).not.toContain(t("composer.chooseFolder"));
    // Not placeholder-styled: no dim mark, no inline muted colour, the same label element a picked
    // folder uses.
    expect(chip.querySelector("[data-dim]")).toBeNull();
    expect((label as HTMLElement).style.color).toBe("");
  });

test("a picked folder and No folder draw the same label element", async () => {
  const empty = await folderChip(base);
  const emptyClass = empty.querySelector(".acpmux-location-label")?.className;
  act(() => root?.unmount());
  host.replaceChildren();
  const picked = await folderChip({
    ...base,
    summary: { sessionId: "", harness: "claude", cwd: "/Users/you/src/cmux" },
  });
  expect(picked.textContent).toContain("cmux");
  expect(picked.querySelector("[data-middle], .acpmux-location-label")).toBeTruthy();
  expect(emptyClass).toBe("acpmux-location-label");
});

// Detector: the folder chip's faces (ComposerContext, ProjectChooser) never fall back to the
// "Choose folder" placeholder, and the dimmed label style does not come back.
test("detector: no Choose folder placeholder on the folder chip's faces", () => {
  const src = join(import.meta.dir, "../src/agent-session/acpmux");
  const context = readFileSync(join(src, "ComposerContext.tsx"), "utf8");
  const chooser = readFileSync(join(src, "ProjectChooser.tsx"), "utf8");
  const css = readFileSync(join(src, "composerLocation.css"), "utf8");
  expect(context).not.toMatch(/CONTEXT_LABELS\.chooseFolder\b/);
  expect(context).not.toMatch(/\bdim=\{/);
  expect(chooser).not.toMatch(/currentLabel \?\? t\("composer\.chooseFolder"\)/);
  expect(css).not.toMatch(/acpmux-location-label\[data-dim\]/);
});
