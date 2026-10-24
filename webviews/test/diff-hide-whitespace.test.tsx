// Hide white space in the diff viewer's "..." menu (Codex parity D5): the row was always
// unavailable. Now a host whose sidecar honors `ignoreWhitespace` (its config's
// `sessionCapabilities`) turns it on for the git sources, the toggle asks the next session to
// diff with `--ignore-all-space`, and the choice persists as the `diff.hideWhitespace` setting.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { DiffSource } from "../src/diff/generated/protocol";
import type { DiffTransport } from "../src/diff/transport";
import { diffSessionRequest, HIDE_WHITESPACE_CAPABILITY, hideWhitespaceAvailable } from "../src/diff-viewer/session";
import { NO_HOST_CAPABILITIES, overflowMenuItems } from "../src/toolbar-model";
import { blobFingerprint, patchFingerprint, toggleViewedItem, viewedStateOfItem } from "../src/viewed-files";
import { sanitizeViewerPrefs } from "../src/viewer-prefs";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "Element",
  "getComputedStyle",
  "localStorage",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const transport = {} as DiffTransport;
const unstaged: DiffSource = { kind: "unstaged", repoRoot: "/repo" };
const staged: DiffSource = { kind: "staged", repoRoot: "/repo" };
const branch: DiffSource = { kind: "branch", repoRoot: "/repo", baseRef: "main" };
const patch: DiffSource = { kind: "patch", path: "/tmp/a.patch" };
/** What the app's host sends (DiffPageConfig.swift). */
const appPayload = { capabilityToken: "token", sessionCapabilities: [HIDE_WHITESPACE_CAPABILITY] };

test("the row applies to git sources on a host whose sidecar hides white space", () => {
  for (const source of [unstaged, staged, branch]) {
    expect(hideWhitespaceAvailable(appPayload, source)).toBe(true);
  }
  // A patch file is fixed text: the sidecar cannot diff it again.
  expect(hideWhitespaceAvailable(appPayload, patch)).toBe(false);
  expect(hideWhitespaceAvailable(appPayload, null)).toBe(false);
  // The classic viewer and older hosts name no capability.
  expect(hideWhitespaceAvailable({ capabilityToken: "token" }, unstaged)).toBe(false);
  expect(hideWhitespaceAvailable({ sessionCapabilities: "session.ignoreWhitespace" }, unstaged)).toBe(false);
});

test("the next session asks for ignoreWhitespace only when it is on and can apply", () => {
  expect(diffSessionRequest(appPayload, transport, unstaged, true)).toEqual({
    source: unstaged,
    capabilityToken: "token",
    ignoreWhitespace: true,
  });
  // Off, the request is the one the viewer always sent.
  expect(diffSessionRequest(appPayload, transport, unstaged, false)).toEqual({
    source: unstaged,
    capabilityToken: "token",
  });
  expect(diffSessionRequest(appPayload, transport, unstaged)).toEqual({ source: unstaged, capabilityToken: "token" });
  expect(diffSessionRequest(appPayload, transport, patch, true)).toEqual({ source: patch, capabilityToken: "token" });
  expect(diffSessionRequest({ capabilityToken: "token" }, transport, branch, true)).toEqual({
    source: branch,
    capabilityToken: "token",
  });
});

test("the menu row is checked only where it applies", () => {
  const row = (hideWhitespace: boolean, available: boolean) =>
    overflowMenuItems(
      { hideImports: false, hideWhitespace, loadFullFiles: false, richPreview: false, wordDiffs: true },
      { ...NO_HOST_CAPABILITIES, hideWhitespace: available },
    ).find((item) => item.id === "hide-whitespace");
  expect(row(true, true)).toMatchObject({ available: true, checked: true });
  expect(row(false, true)).toMatchObject({ available: true, checked: false });
  expect(row(true, false)).toMatchObject({ available: false, checked: false });
});

test("the choice persists as a boolean pref, off by default", async () => {
  expect(sanitizeViewerPrefs({ hideWhitespace: true })).toEqual({ hideWhitespace: true });
  expect(sanitizeViewerPrefs({ hideWhitespace: "yes" })).toEqual({});
  const { initialAppState } = await import("../src/diff-viewer/state");
  const page = { transport: { kind: "page" as const, endpoint: "cmux.diff", protocolVersion: 1 } };
  expect(initialAppState({ payload: page }, "loading" as never).options.hideWhitespace).toBe(false);
  expect(
    initialAppState({ payload: { ...page, viewerOptions: { hideWhitespace: true } } }, "loading" as never).options
      .hideWhitespace,
  ).toBe(true);
});

async function renderPill(available: boolean, hideWhitespace: boolean) {
  const { createRoot } = await import("react-dom/client");
  const { DiffPill } = await import("../src/diff-viewer/Toolbar");
  const { initialAppState } = await import("../src/diff-viewer/state");
  const { createDiffViewerLabelResolver } = await import("../src/labels");
  const base = initialAppState({ payload: {} }, "loading" as never);
  const state = { ...base, optionsOpen: true, options: { ...base.options, hideWhitespace } };
  const set: [string, unknown][] = [];
  const noop = () => {};
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <DiffPill
        capabilities={{ ...NO_HOST_CAPABILITIES, hideWhitespace: available }}
        dispatch={noop}
        externalURL={null}
        label={createDiffViewerLabelResolver(undefined, { language: "en" })}
        onCopyGitApply={noop}
        onReload={noop}
        onSetLayout={noop}
        onSetOption={(key, value) => set.push([key, value])}
        state={state}
      />,
    ),
  );
  const row = document.querySelector<HTMLButtonElement>('[data-option="hide-whitespace"]')!;
  return { row, set };
}

test("choosing the row toggles the option", async () => {
  const off = await renderPill(true, false);
  expect(off.row.getAttribute("aria-disabled")).toBeNull();
  expect(off.row.getAttribute("aria-checked")).toBe("false");
  await act(async () => off.row.click());
  expect(off.set).toEqual([["hideWhitespace", true]]);

  const on = await renderPill(true, true);
  expect(on.row.getAttribute("aria-checked")).toBe("true");
  await act(async () => on.row.click());
  expect(on.set).toEqual([["hideWhitespace", false]]);
});

test("an unavailable row does nothing and says why", async () => {
  const { row, set } = await renderPill(false, true);
  expect(row.getAttribute("aria-disabled")).toBe("true");
  expect(row.getAttribute("aria-checked")).toBe("false");
  expect(row.title).not.toBe("");
  await act(async () => row.click());
  expect(set).toEqual([]);
});

test("the check mark follows what the shown session did, once it answered", () => {
  const row = (hideWhitespace: boolean, whitespaceHidden: boolean | null) =>
    overflowMenuItems(
      { hideImports: false, hideWhitespace, loadFullFiles: false, richPreview: false, wordDiffs: true },
      { ...NO_HOST_CAPABILITIES, hideWhitespace: true },
      whitespaceHidden,
    ).find((item) => item.id === "hide-whitespace");
  // A session that did not hide white space (an older sidecar) shows the row unchecked.
  expect(row(true, false)?.checked).toBe(false);
  expect(row(false, true)?.checked).toBe(true);
  // While the session opens, the choice.
  expect(row(true, null)?.checked).toBe(true);
});

test("a patch with white space hidden is never copied as a git apply command", () => {
  const copyRow = (whitespaceHidden: boolean | null) =>
    overflowMenuItems(
      { hideImports: false, hideWhitespace: true, loadFullFiles: false, richPreview: false, wordDiffs: true },
      { ...NO_HOST_CAPABILITIES, hideWhitespace: true },
      whitespaceHidden,
    ).find((item) => item.id === "copy-git-apply");
  expect(copyRow(true)).toMatchObject({ available: false, unavailableKey: "copyNeedsWhitespaceShown" });
  expect(copyRow(false)).toMatchObject({ available: true });
  expect(copyRow(null)).toMatchObject({ available: true });
});

test("the diff's own state: the session's answer, reset by a reload, and boot prefs never flip it", async () => {
  const { initialAppState, reducer } = await import("../src/diff-viewer/state");
  const base = initialAppState({ payload: { viewerOptions: { hideWhitespace: true } } }, "loading" as never);
  expect(base.whitespaceHidden).toBeNull();
  const answered = reducer(base, { type: "set-whitespace-hidden", hidden: true });
  expect(answered.whitespaceHidden).toBe(true);
  const status = base.status;
  expect(reducer(answered, { type: "refresh", status }).whitespaceHidden).toBeNull();
  expect(reducer(answered, { type: "reset-diff", status }).whitespaceHidden).toBeNull();
  // The session already opened with the seeded choice; a later prefs read must not change it.
  const booted = reducer(answered, {
    type: "apply-persisted-options",
    prefs: { hideWhitespace: false, wordWrap: true },
    allowLayout: true,
  });
  expect(booted.options.hideWhitespace).toBe(true);
  expect(booted.options.wordWrap).toBe(true);
});

/** One file's patch, as the sidecar streams it, with white space shown and hidden. */
const header = [
  "diff --git a/story.txt b/story.txt",
  "index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644",
  "--- a/story.txt",
  "+++ b/story.txt",
];
const shownPatch = [...header, "@@ -1,3 +1,3 @@", " one", "-two", "-three", "+ two", "+THREE", ""].join("\n");
const hiddenPatch = [...header, "@@ -1,3 +1,3 @@", " one", "  two", "-three", "+THREE", ""].join("\n");

test("a Viewed mark keys on the file's blobs, so Hide white space does not flip it", () => {
  expect(patchFingerprint(shownPatch)).not.toBe(patchFingerprint(hiddenPatch));
  expect(blobFingerprint(shownPatch)).toBe(blobFingerprint(hiddenPatch));
  expect(blobFingerprint(shownPatch)).toStartWith("blob:");
  // Another blob is another fingerprint.
  expect(blobFingerprint(shownPatch.replace("2222", "3333"))).not.toBe(blobFingerprint(shownPatch));
  // A pure rename has no index line, and keeps the patch fingerprint.
  expect(blobFingerprint("diff --git a/a b/b\nsimilarity index 100%\nrename from a\nrename to b\n")).toBeUndefined();

  const item = (patch: string) => ({
    id: "story.txt",
    fileDiff: {
      name: "story.txt",
      cmuxPatchFingerprint: patchFingerprint(patch),
      cmuxBlobFingerprint: blobFingerprint(patch),
    },
  });
  const marked = toggleViewedItem([item(shownPatch)], new Map(), "story.txt");
  expect(viewedStateOfItem(item(shownPatch), marked.viewedByPath)).toBe("viewed");
  expect(viewedStateOfItem(item(hiddenPatch), marked.viewedByPath)).toBe("viewed");
  // A mark stored before the blob fingerprint (the patch's) still counts while the patch is the same.
  const legacy = new Map([["story.txt", { path: "story.txt", fingerprint: patchFingerprint(shownPatch) }]]);
  expect(viewedStateOfItem(item(shownPatch), legacy)).toBe("viewed");
  // A real edit still reads as changed since viewed.
  expect(viewedStateOfItem(item(shownPatch.replace("2222", "3333")), marked.viewedByPath)).toBe("changed");
});
