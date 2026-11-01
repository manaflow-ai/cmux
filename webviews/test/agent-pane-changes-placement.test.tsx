// The chat's changes view opens on the right, beside the transcript, never over it (Leo, 2026-10-31:
// "and why does it still not open to the right"). When the chat folder's diff can't open in its own
// pane beside the chat (a folder outside a repository, a turn that wrote outside it), the turn's diff
// opens in the page; it used to sit beside the transcript only in a pane 1160px wide or more and to
// cover the chat below that. The view's Commit and Push read the branch with `git.status`; a folder
// that is not a repository has no branch, and that is not an error ("The branch state could not be
// read" showed over every such view).
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { isNoRepository } from "../src/agent-session/acpmux/changes/gitWrite";
import { useGitWrite, type GitWrite } from "../src/agent-session/acpmux/changes/useGitWrite";
import type { ChangesSource } from "../src/agent-session/acpmux/changes/model";
import { NativeError } from "../src/agent-session/acpmux/nativeError";

const sheet = (relative: string) =>
  readFileSync(new URL(`../src/agent-session/acpmux/${relative}`, import.meta.url), "utf8");

/// The at-rule blocks (`@container`, `@media`, `@supports`) enclosing `index` in `css`.
function enclosingAtRules(css: string, index: number): string[] {
  const stack: string[] = [];
  let start = 0;
  for (let at = 0; at < index; at++) {
    const char = css[at];
    if (char === "{") {
      stack.push(css.slice(start, at).trim());
      start = at + 1;
    } else if (char === "}") {
      stack.pop();
      start = at + 1;
    } else if (char === ";") start = at + 1;
  }
  return stack.filter((prelude) => prelude.startsWith("@"));
}

/// Every declaration block whose selector list names `selector`, with the at-rules around it.
function rulesFor(css: string, selector: string): { body: string; atRules: string[] }[] {
  const plain = css.replace(/\/\*[\s\S]*?\*\//g, (comment) => " ".repeat(comment.length));
  const found: { body: string; atRules: string[] }[] = [];
  const pattern = /([^{}]+)\{([^{}]*)\}/g;
  for (let match = pattern.exec(plain); match; match = pattern.exec(plain)) {
    const selectors = match[1]!.split(",").map((part) => part.replace(/\s+/g, "").trim());
    if (selectors.includes(selector)) found.push({ body: match[2]!, atRules: enclosingAtRules(plain, match.index) });
  }
  return found;
}

const paneSheets = ["styles.css", "header/header.css", "conversation/conversation.css", "Inspector.css"];

test("the in-page changes view sits right of the transcript at every pane width", () => {
  const header = sheet("header/header.css");
  const panel = rulesFor(header, ".acpmux-reviewing>.acpmux-diff-panel");
  expect(panel.length).toBe(1);
  // Not only in a wide pane: no container or media query decides it.
  expect(panel[0]!.atRules).toEqual([]);
  expect(panel[0]!.body).toMatch(/left:var\(--acpmux-review-chat\)/);
  const transcript = rulesFor(header, ".acpmux-reviewing>.acpmux-scroll");
  expect(
    transcript.some(
      (rule) =>
        rule.atRules.length === 0 &&
        /margin-right:calc\(100%-var\(--acpmux-review-chat\)\)/.test(rule.body.replace(/\s+/g, "")),
    ),
  ).toBe(true);
  const split = rulesFor(header, ".acpmux-reviewing");
  expect(split.some((rule) => rule.atRules.length === 0 && /--acpmux-review-chat:/.test(rule.body))).toBe(true);
});

test("no pane sheet hides the transcript or the chat header while changes are open", () => {
  for (const name of paneSheets) {
    const css = sheet(name);
    for (const selector of [".acpmux-reviewing>.acpmux-scroll", ".acpmux-reviewing>.acpmux-header"])
      for (const rule of rulesFor(css, selector)) {
        expect(`${name}: ${rule.body}`).not.toMatch(/visibility:\s*hidden|display:\s*none/);
      }
  }
});

test("the changes view's file tree gives way by the panel's own width, not only the window's", () => {
  // Beside the transcript the panel can be ~320px of a 640px pane; a 250px tree there leaves no room for the diff.
  const styles = sheet("styles.css");
  const panel = rulesFor(styles, ".acpmux-diff-panel").find((rule) => /position:absolute/.test(rule.body));
  expect(panel?.body.replace(/\s+/g, "")).toMatch(/container:acpmux-diff-panel\/inline-size/);
  const tree = rulesFor(styles, ".acpmux-diff-tree").filter((rule) => /display:none/.test(rule.body));
  expect(tree.some((rule) => rule.atRules.includes("@container acpmux-diff-panel (max-width:620px)"))).toBe(true);
});

const notARepository = () =>
  new NativeError({
    code: "operation.failed",
    origin: "session_host",
    userMessage: "The request failed.",
    details: { operation: "git.status", extra: { code: "not_a_repository", path: "/Users/you/Projects" } },
  });

test("a status read that says the folder is not in a repository is not a failure", () => {
  expect(isNoRepository(notARepository())).toBe(true);
  expect(isNoRepository(new NativeError({ code: "native.timed_out", origin: "native" }))).toBe(false);
  expect(
    isNoRepository(
      new NativeError({ code: "operation.failed", origin: "session_host", details: { extra: { code: "git_failed" } } }),
    ),
  ).toBe(false);
  expect(isNoRepository(new Error("boom"))).toBe(false);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
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

async function readGit(status: () => Promise<unknown>): Promise<GitWrite> {
  const source = {
    diff: async () => ({ files: [] }),
    status,
    commit: async () => ({}),
    push: async () => ({}),
  } as unknown as ChangesSource;
  let latest: GitWrite | undefined;
  function Probe() {
    latest = useGitWrite(source, () => undefined);
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => await Promise.resolve());
  return latest!;
}

test("a folder outside a repository gets no Commit, no Push and no branch error", async () => {
  const git = await readGit(() => Promise.reject(notARepository()));
  expect(git.statusFailed).toBe(false);
  expect(git.available).toBe(false);
});

test("a status read that fails for another reason still says so", async () => {
  const git = await readGit(() => Promise.reject(new NativeError({ code: "native.timed_out", origin: "native" })));
  expect(git.statusFailed).toBe(true);
  expect(git.available).toBe(true);
});

test("a repository made while the view is open brings Commit and Push back on the next check", async () => {
  let initialized = false;
  const source = {
    diff: async () => ({ files: [] }),
    status: () =>
      initialized
        ? Promise.resolve({ detached: false, head: "abc123", branch: "main", ahead: 0, behind: 0 })
        : Promise.reject(notARepository()),
    commit: async () => ({}),
    push: async () => ({}),
  } as unknown as ChangesSource;
  let latest: GitWrite | undefined;
  function Probe() {
    latest = useGitWrite(source, () => undefined);
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => await Promise.resolve());
  expect(latest!.available).toBe(false);
  expect(latest!.statusFailed).toBe(false);
  initialized = true;
  await act(async () => latest!.recheck());
  await act(async () => await Promise.resolve());
  expect(latest!.available).toBe(true);
  expect(latest!.status?.branch).toBe("main");
});
