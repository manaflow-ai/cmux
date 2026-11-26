// A Cloud chat with no folder is a first-class start (folderlessCloud.ts). Leo, 2026-11-09: "We need
// to be able to have it so, like, this no folder selected should be, like, good as well."
//   - Cloud picked and no folder: the folder chip reads No folder, not dimmed, and says where the
//     chat starts (a fresh folder on the machine) as its description (the folder menu has no line of it);
//   - it never reads an empty "Choose folder" while Cloud is the pick;
//   - This Mac with no folder reads No folder too, with no Cloud detail; a picked folder keeps its
//     name under Cloud;
//   - a started Cloud chat in the fresh folder its machine made (`~/chats/<chat>`) names that
//     folder: No folder is only the unsent chat's state.
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

test("Cloud uses the Mac folder’s GitHub repository when known, else shows No folder", async () => {
  const cwd = "/Users/you/src/cmux";
  const summary = { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" as const, cwd };
  await mount({ ...cloud, summary });
  expect(folderLabel()?.textContent).toBe(t("composer.cloudNoFolder"));
  await mount({
    ...cloud,
    summary,
    projectChoices: [{ cwd, label: "cmux", repo: { name: "cmux", root: cwd, github: "acme/cmux" } }],
  });
  expect(folderLabel()?.textContent).toBe("acme/cmux");
});

test("a started Cloud chat in its machine's fresh folder names that folder, not No folder", async () => {
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
  expect(stripText()).toContain("peer-4242");
  expect(stripText()).not.toContain(t("composer.cloudNoFolder"));
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

test("a Cloud source without a GitHub remote starts without a copied folder", async () => {
  const { cloudStartFolder } = await import("../src/agent-session/acpmux/cloudRun");
  const { cloudRepositoryPick } = await import("../src/agent-session/acpmux/sourcePickerModel");
  for (const cwd of [undefined, "/Users/you/src/cmux/", "/Users/you/Library/Application Support/cmux/agent-home/abc"]) {
    const selected = cloudRepositoryPick(cwd);
    await mount({ ...cloud, summary: { sessionId: "", cwd } });
    expect(folderLabel()?.dataset.folderState).toBe("cloudFresh");
    expect(cloudStartFolder(selected)).toEqual({ home: true });
  }
  expect(cloudStartFolder(cloudRepositoryPick("/Users/you/src/cmux", "acme/cmux"))).toEqual({
    cwd: "github:acme/cmux",
  });
});

// cmux#46023: a Cloud chat started with a folder from a New Tab page read No folder beside Cloud. The page's
// Cloud send hands its folder to the start (App.tsx `onCloud`), never to the page's folder pick, so the chat
// composer the page gives way to while the start is out had no folder to name. The composer names the folder
// the shown start copies (newtab/draftFolder.ts `withCloudStartFolder`), the start's own `cwd`.
test("a Cloud start sent with a folder names that folder while it is out, never No folder", async () => {
  const { cloudStartBegun } = await import("../src/agent-session/acpmux/cloudStartProgress");
  const { withCloudStartFolder, withDraftFolder } = await import("../src/agent-session/acpmux/newtab/draftFolder");
  const start = cloudStartBegun("k-1", "whats in my folder", "/Users/you/src/myfolder/", "Claude Code");
  expect(start.cwd).toBe("/Users/you/src/myfolder");
  const page = {
    sessionId: undefined,
    summary: { sessionId: "", harness: "codex", model: "gpt-6", host: "This Mac", hostKind: "local" },
  } as unknown as Parameters<typeof withCloudStartFolder>[0];
  // No folder pick on the page (the New Tab send never makes one): the start's folder is the chip's.
  const shown = withCloudStartFolder(withDraftFolder(page, undefined), start.cwd);
  // Only the folder changes: the chips still name the agent and model the start sends.
  expect(shown.summary).toMatchObject({ harness: "codex", model: "gpt-6", cwd: "/Users/you/src/myfolder" });
  await mount({ ...cloud, cloudStartOut: true, summary: shown.summary });
  const label = folderLabel();
  // A start that is out shows its folder as a plain label (folderlessCloud.ts `folderMenu`).
  expect(label?.textContent).toBe("myfolder");
  expect(stripText()).not.toContain(t("composer.cloudNoFolder"));
  // The page without it, as before the fix: the same start read No folder.
  await mount({ ...cloud, cloudStartOut: true, summary: page.summary });
  expect(folderLabel()?.textContent).toBe(t("composer.cloudNoFolder"));
});

// cmux#53226: a GitHub repository picked for a Cloud chat turned into a plain folder icon on Return; its start is a
// clone of the repository, and the chip keeps the repository's logo while it is out.
test("a Cloud start of a GitHub repository keeps the GitHub logo and its name while it is out", async () => {
  const { cloudStartBegun } = await import("../src/agent-session/acpmux/cloudStartProgress");
  const { withCloudStartFolder, withDraftFolder } = await import("../src/agent-session/acpmux/newtab/draftFolder");
  const start = cloudStartBegun("k-3", "whats in this pr?", "github:manaflow-ai/cmuxterm-hq", "Claude Code");
  const page = {
    sessionId: undefined,
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
  } as unknown as Parameters<typeof withCloudStartFolder>[0];
  const shown = withCloudStartFolder(withDraftFolder(page, undefined), start.cwd);
  await mount({ ...cloud, cloudStartOut: true, summary: shown.summary });
  expect(folderLabel()?.textContent).toBe("manaflow-ai/cmuxterm-hq");
  const chip = folderLabel()?.parentElement;
  // The GitHub glyph (GitHubIcons.tsx), not the folder icon.
  expect(chip?.querySelector('svg[viewBox="-2 -2 20 20"]')).not.toBeNull();
  expect(chip?.querySelector(".acpmux-location-icon")).toBeNull();
});

test("a folderless Cloud start still reads No folder while it is out", async () => {
  const { cloudStartBegun } = await import("../src/agent-session/acpmux/cloudStartProgress");
  const { withCloudStartFolder } = await import("../src/agent-session/acpmux/newtab/draftFolder");
  const start = cloudStartBegun("k-2", "hello", undefined, "Claude Code", true);
  expect(start.cwd).toBeUndefined();
  const page = {
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
  } as unknown as Parameters<typeof withCloudStartFolder>[0];
  expect(withCloudStartFolder(page, start.cwd)).toBe(page);
  await mount({ ...cloud, cloudStartOut: true, summary: page.summary });
  expect(folderLabel()?.textContent).toBe(t("composer.cloudNoFolder"));
});

test("a chat that has a session keeps its own folder, never a Cloud start's", async () => {
  const { withCloudStartFolder } = await import("../src/agent-session/acpmux/newtab/draftFolder");
  const chat = {
    sessionId: "s-1",
    summary: { sessionId: "s-1", harness: "claude", cwd: "/Users/you/src/cmux" },
  } as unknown as Parameters<typeof withCloudStartFolder>[0];
  expect(withCloudStartFolder(chat, "/Users/you/src/other")).toBe(chat);
});
