// A chat's changes open in a diff tab beside the chat (5c388eb6 removed the in-page view). Commit
// and Push read the branch with `git.status`; a folder that is not a repository has no branch, and
// that is not an error ("The branch state could not be read" showed over every such view).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { isNoRepository } from "../src/agent-session/acpmux/changes/gitWrite";
import { useGitWrite, type GitWrite } from "../src/agent-session/acpmux/changes/useGitWrite";
import type { ChangesSource } from "../src/agent-session/acpmux/changes/model";
import { NativeError } from "../src/agent-session/acpmux/nativeError";
import { settleReact } from "./support/domTeardown";

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
  await settleReact();
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
