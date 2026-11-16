// A Cloud chat with no folder is a first-class start (folderlessCloud.ts). Leo, 2026-11-09: "We need
// to be able to have it so, like, this no folder selected should be, like, good as well."
//   - Cloud picked and no folder: the folder chip reads No folder, not dimmed, and says where the
//     chat starts (a fresh folder on the machine) as its description and in the folder menu;
//   - it never reads an empty "Choose folder" while Cloud is the pick;
//   - This Mac with no folder reads No folder too, with no Cloud detail; a picked folder keeps its
//     name under Cloud;
//   - a started Cloud chat in the fresh folder its machine made (`~/chats/<chat>`) reads No folder,
//     not the folder's generated name.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "PointerEvent",
  "Event",
  "CustomEvent",
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

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    FocusEvent: dom.window.FocusEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
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
  (await import("../src/agent-session/acpmux/native")).setNativeHost(async () => ({}));
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/native")).setNativeHost(undefined);
  await teardownDom(saved, { window: dom.window, scope });
});

const flush = () => act(async () => await new Promise((done) => setTimeout(done, 0)));

async function mount(extra: Record<string, unknown>) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const props = {
    environments: true,
    stripLayout: "where-machine",
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
    localName: "studio-mac",
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    onProject: () => undefined,
    onConnect: () => undefined,
    cloudSignedIn: true,
    ...extra,
  } as unknown as Parameters<typeof ComposerContext>[0];
  root ??= createRoot(host);
  await act(async () => root!.render(<ComposerContext {...props} />));
  await flush();
}

const cloud = { runMode: { mode: "cloud", onMode: () => undefined } };
const thisMac = { runMode: { mode: "persistent", onMode: () => undefined } };
const stripText = () => host.querySelector(".acpmux-location-leading")?.textContent ?? "";
const folderLabel = () => host.querySelector<HTMLElement>(".acpmux-location-leading .acpmux-location-label");

test("Cloud with no folder: the chip reads No folder, a valid state with its one line of detail", async () => {
  await mount(cloud);
  const label = folderLabel();
  expect(label?.textContent).toBe(t("composer.cloudNoFolder"));
  expect(label?.dataset.folderState).toBe("cloudFresh");
  expect(label?.hasAttribute("data-dim")).toBe(false);
  expect(label?.getAttribute("aria-description")).toBe(t("composer.cloudNoFolderDetail"));
  expect(stripText()).not.toContain(t("composer.chooseFolder"));
});

test("This Mac with no folder reads No folder too, the same width, with no Cloud detail", async () => {
  await mount(thisMac);
  const label = folderLabel();
  // The same words as the Cloud face, so picking Cloud moves nothing after the chip
  // (cloud-environment-chip-geometry.test.ts measures it in Chromium).
  expect(label?.textContent).toBe(t("composer.cloudNoFolder"));
  expect(label?.dataset.folderState).toBe("choose");
  expect(label?.hasAttribute("data-dim")).toBe(false);
  expect(label?.hasAttribute("aria-description")).toBe(false);
});

test("Cloud with a folder picked keeps the folder's name: choosing a folder still works", async () => {
  await mount({
    ...cloud,
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local", cwd: "/Users/you/src/cmux" },
  });
  expect(stripText()).toContain("cmux");
  expect(stripText()).not.toContain(t("composer.cloudNoFolder"));
});

test("a started Cloud chat in its machine's fresh folder reads No folder, not the folder's generated name", async () => {
  await mount({
    started: true,
    onNewChat: () => undefined,
    peers: ["zesty-indigo-lemur"],
    peerKinds: { "zesty-indigo-lemur": "cloud" },
    summary: {
      sessionId: "s-1",
      harness: "claude",
      host: "zesty-indigo-lemur",
      hostKind: "cloud",
      peer: "zesty-indigo-lemur",
      cwd: "/home/cmux/chats/peer-4242",
    },
  });
  expect(stripText()).toContain(t("composer.cloudNoFolder"));
  expect(stripText()).not.toContain("peer-4242");
});

test("an SSH chat in a folder shaped like a Cloud chat's keeps its name: only Cloud chats have a fresh folder", async () => {
  await mount({
    started: true,
    onNewChat: () => undefined,
    peers: ["build-box"],
    peerKinds: { "build-box": "ssh" },
    summary: {
      sessionId: "s-2",
      harness: "claude",
      host: "build-box",
      peer: "build-box",
      cwd: "/home/alice/chats/api",
    },
  });
  expect(stripText()).toContain("api");
  expect(stripText()).not.toContain(t("composer.cloudNoFolder"));
  expect(stripText()).not.toContain(t("composer.chooseFolder"));
});
