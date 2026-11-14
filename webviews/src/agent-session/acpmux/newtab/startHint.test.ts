import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { newTabHost } from "../newTabModel";
import { injectedNewTabContext, sameNewTabScreen } from "./adoption";
import { reconciledProject, startFromContext } from "./startHint";
import { settleReact } from "../../../../test/support/domTeardown";

// Leo, 2026-11-03: "the read defaults/the "not working in a project" thing that should all be
// instant". The New Tab context the host injects as the document commits carries the chat's start,
// so the first render already has the project (or no project) the handshake would answer.

let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const PROJECT = "/Users/you/src/app";

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "localStorage", "sessionStorage"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    sessionStorage: dom.window.sessionStorage,
  });
});

afterEach(async () => {
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const inject = (context: unknown) => {
  (dom!.window as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext = context;
};

test("the first render names the project from the injected context, with no handshake", () => {
  inject({ kind: "agent", cwd: PROJECT, start: { cwd: PROJECT } });
  expect(startFromContext(injectedNewTabContext()?.start)).toEqual({
    newSession: true,
    projectDraft: PROJECT,
    chooseFolder: false,
  });
});

test("a workspace with no folder is in no project on its first render, Choose Folder offered", () => {
  inject({ kind: "agent", cwd: "/Users/you", start: { chooseFolder: true } });
  const start = startFromContext(injectedNewTabContext()?.start);
  expect(start).toEqual({ newSession: true, chooseFolder: true });
  expect(start?.projectDraft).toBeUndefined();
});

test("a context without a start (an older host) leaves the start to the handshake", () => {
  inject({ kind: "agent", cwd: PROJECT });
  expect(injectedNewTabContext()?.start).toBeUndefined();
  expect(startFromContext(injectedNewTabContext()?.start)).toBeUndefined();
  // A start folder that is no absolute path is not taken as one.
  expect(newTabHost({ newTab: { start: { cwd: "src/app" } } })?.start).toEqual({ chooseFolder: false });
});

test("the store's answer reconciles the first frame's project only when it differs", () => {
  // The same answer: nothing changes.
  expect(reconciledProject(PROJECT, PROJECT, PROJECT)).toBe(PROJECT);
  // Another folder (a symlink's canonical path, a folder the store picked): it replaces it.
  expect(reconciledProject(PROJECT, PROJECT, "/Volumes/src/app")).toBe("/Volumes/src/app");
  // No folder (the folder is gone: agent-home): the context's folder goes.
  expect(reconciledProject(PROJECT, PROJECT, undefined)).toBeUndefined();
  // A folder the person picked before the answer stays.
  expect(reconciledProject("/Users/you/src/other", PROJECT, undefined)).toBe("/Users/you/src/other");
});

test("an adopt that differs only in its start keeps the screen mounted", () => {
  const prepared = newTabHost({ newTab: { kind: "agent", cwd: PROJECT } })!;
  const adopted = newTabHost({ newTab: { kind: "agent", cwd: PROJECT, start: { cwd: PROJECT } } })!;
  expect(adopted.start).toEqual({ cwd: PROJECT, chooseFolder: false });
  expect(sameNewTabScreen(prepared, adopted)).toBe(true);
});
