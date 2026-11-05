// Word changes in the diff viewer (#23154): on by default in cmux NEXT, where the display options
// are `diff.*` settings, and still off in the classic viewer, which got no reviewed default change.
// cmux NEXT's defaults are the settings schema's (DiffViewerSettingsSchema.swift, exported to
// schemas/settings/settings-schema.json), so a default changed on one side only fails here.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import exported from "../../schemas/settings/settings-schema.json";
import type { DiffViewerPayload } from "../src/types";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "Element",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

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
    localStorage: window.localStorage,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** What cmux NEXT's page host sends (DiffPageConfig.swift), and what the classic CLI embeds. */
const nextPayload: DiffViewerPayload = { transport: { kind: "page", endpoint: "cmux.diff", protocolVersion: 1 } };
const classicPayload: DiffViewerPayload = { transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 } };

async function initialOptions(payload: DiffViewerPayload) {
  const { initialAppState } = await import("../src/diff-viewer/state");
  return initialAppState({ payload }, "loading" as never).options;
}

test("the classic viewer starts with word changes off", async () => {
  expect((await initialOptions(classicPayload)).wordDiffs).toBe(false);
  // The dev server's config (fetch transport) and a config with no transport are classic too.
  const devServer: DiffViewerPayload = { transport: { kind: "fetch", endpoint: "/rpc", protocolVersion: 1 } };
  expect((await initialOptions(devServer)).wordDiffs).toBe(false);
  expect((await initialOptions({})).wordDiffs).toBe(false);
});

test("cmux NEXT starts with word changes on", async () => {
  expect((await initialOptions(nextPayload)).wordDiffs).toBe(true);
});

test("a stored pref wins over the default on either host", async () => {
  expect((await initialOptions({ ...nextPayload, viewerOptions: { wordDiffs: false } })).wordDiffs).toBe(false);
  expect((await initialOptions({ ...classicPayload, viewerOptions: { wordDiffs: true } })).wordDiffs).toBe(true);
});

test("cmux NEXT's defaults are the diff settings' schema defaults", async () => {
  const { defaultDiffViewerOptions } = await import("../src/diff-viewer/state");
  const rows = (exported as unknown as { rows: { key: string; default: unknown }[] }).rows;
  const schemaDefault = (key: string) => rows.find((row) => row.key === `diff.${key}`)?.default;
  const { sanitizeViewerPrefs } = await import("../src/viewer-prefs");
  const defaults = defaultDiffViewerOptions(nextPayload);
  expect(Object.keys(defaults).length).toBeGreaterThan(0);
  for (const [key, value] of Object.entries(defaults)) {
    // Hide imports, rich preview and full files last for the tab (viewer-prefs-host-keys.test.ts):
    // the page never persists them and the schema has no row for them.
    const persisted = key in sanitizeViewerPrefs({ [key]: value });
    expect({ key, value: schemaDefault(key) }).toEqual({ key, value: persisted ? value : undefined });
  }
  expect(schemaDefault("wordDiffs")).toBe(true);
});
