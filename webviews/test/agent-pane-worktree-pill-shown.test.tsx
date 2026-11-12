// The header's worktree pill reads the session host's `git.status` again each time its chat starts
// or ends a turn (the branch may have changed). A chat nobody looks at ran the same reads: about 50
// agents that end turns in bursts each ran a git process for a pill no one saw, in front of the
// `git.status` of the view the person looked at (Lawrence's nightly ef384ddbc64d, 2026-11-11: 49
// `git.status` in 35 minutes, 1.8 s the slowest). A hidden chat's refresh now waits until the chat
// shows, and then runs once.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { useWorktree } = await import("../src/agent-session/acpmux/header/worktreePillModel");

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

/// Hides or shows the page, as the host does for a chat behind another tab or workspace.
async function setPageShown(shown: boolean) {
  Object.defineProperty(dom.window.document, "visibilityState", {
    configurable: true,
    get: () => (shown ? "visible" : "hidden"),
  });
  await act(async () => {
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
  });
  await settle();
}

/// A session host whose folders are each a worktree; `branches` names the branch a read answers.
function host() {
  const reads: string[] = [];
  const branches = new Map<string, string>();
  const readStatus = (cwd: string) => {
    reads.push(cwd);
    return Promise.resolve({ branch: branches.get(cwd) ?? "first", base: "main", worktree: { main_root: "/repo" } });
  };
  return { reads, branches, readStatus, count: (cwd: string) => reads.filter((read) => read === cwd).length };
}

test("a hidden chat's turns ask no git.status; the chat asks once when it shows", async () => {
  const git = host();
  const seen: (string | undefined)[] = [];
  function Probe(props: { folder: string; working: boolean }) {
    const worktree = useWorktree(props.folder, git.readStatus, props.working);
    React.useLayoutEffect(() => {
      seen.push(worktree?.branch);
    });
    return null;
  }
  const folder = "/repo-wt-hidden";
  await setPageShown(true);
  await act(async () => root.render(<Probe folder={folder} working={false} />));
  await settle();
  expect(git.count(folder)).toBe(1);
  expect(seen.at(-1)).toBe("first");

  // Behind another tab, the chat runs two turns that end on another branch.
  await setPageShown(false);
  git.branches.set(folder, "second");
  for (const working of [true, false, true, false]) {
    await act(async () => root.render(<Probe folder={folder} working={working} />));
    await settle();
  }
  expect(git.count(folder)).toBe(1);
  expect(seen.at(-1)).toBe("first");

  // The person comes to the chat: one read for all that happened, and the pill is right.
  await setPageShown(true);
  expect(git.count(folder)).toBe(2);
  expect(seen.at(-1)).toBe("second");

  // Hidden and shown again with no turn between: nothing new to ask.
  await setPageShown(false);
  await setPageShown(true);
  expect(git.count(folder)).toBe(2);
});

test("a shown chat reads its git.status at each turn's start and end, as before", async () => {
  const git = host();
  function Probe(props: { folder: string; working: boolean }) {
    useWorktree(props.folder, git.readStatus, props.working);
    return null;
  }
  const folder = "/repo-wt-shown";
  await setPageShown(true);
  for (const working of [false, true, false]) {
    await act(async () => root.render(<Probe folder={folder} working={working} />));
    await settle();
  }
  expect(git.count(folder)).toBe(3);
});

test("a hidden chat still reads a folder it never read, so its pill is there when it shows", async () => {
  const git = host();
  const seen: (string | undefined)[] = [];
  function Probe(props: { folder: string }) {
    const worktree = useWorktree(props.folder, git.readStatus, false);
    React.useLayoutEffect(() => {
      seen.push(worktree?.branch);
    });
    return null;
  }
  const folder = "/repo-wt-restored";
  await setPageShown(false);
  await act(async () => root.render(<Probe folder={folder} />));
  await settle();
  expect(git.count(folder)).toBe(1);
  expect(seen.at(-1)).toBe("first");
  await setPageShown(true);
  expect(git.count(folder)).toBe(1);
});

test("a shown chat that comes back to a folder reads it again, as before", async () => {
  const git = host();
  function Probe(props: { folder?: string }) {
    useWorktree(props.folder, git.readStatus, false);
    return null;
  }
  const folder = "/repo-wt-back";
  await setPageShown(true);
  // The page shows another chat with no folder (a remote one) and then this chat again.
  for (const next of [folder, undefined, folder]) {
    await act(async () => root.render(<Probe folder={next} />));
    await settle();
  }
  expect(git.count(folder)).toBe(2);
});

test("a hidden chat that left the folder of the read it held back asks nothing for it when it shows", async () => {
  const git = host();
  function Probe(props: { folder?: string; working: boolean }) {
    useWorktree(props.folder, git.readStatus, props.working);
    return null;
  }
  const folder = "/repo-wt-left";
  await setPageShown(true);
  await act(async () => root.render(<Probe folder={folder} working={false} />));
  await settle();
  await setPageShown(false);
  await act(async () => root.render(<Probe folder={folder} working={true} />));
  await settle();
  await act(async () => root.render(<Probe working={false} />));
  await settle();
  await setPageShown(true);
  expect(git.count(folder)).toBe(1);
});

test("showing or hiding the page draws nothing by itself", async () => {
  const git = host();
  let draws = 0;
  function Probe(props: { folder: string }) {
    useWorktree(props.folder, git.readStatus, false);
    draws += 1;
    return null;
  }
  await setPageShown(true);
  await act(async () => root.render(<Probe folder="/repo-wt-still" />));
  await settle();
  const before = draws;
  await setPageShown(false);
  await setPageShown(true);
  expect(draws).toBe(before);
});
