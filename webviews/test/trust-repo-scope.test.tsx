// Leo, 2026-10-21: the trust question must say what is trusted (this folder, the whole repo, or this
// worktree), and a worktree of a trusted repo must inherit its trust with no second question.
// acpmux answers a worktree from its repository (`via`, trust.rs); the pane draws that answer,
// offers Trust repo / Only this folder / Not now, records Trust repo for the repository, and Undo
// forgets the answer where it was made.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
const { readTrust } = await import("../src/agent-session/acpmux/folderTrust");
const { TrustAsk, trustedLabel } = await import("../src/agent-session/acpmux/TrustAsk");
const { translatorFor } = await import("../src/agent-session/acpmux/i18n");
type TrustSource = import("../src/agent-session/acpmux/folderTrust").TrustSource;

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const repoRoot = "/Users/you/Projects/atlas-web";
const worktree = "/Users/you/.cmux/worktrees/atlas-web/fix-retry";

/// acpmux in miniature: a record keyed by folder, a worktree answered from its repository.
function daemon() {
  const record = new Map<string, string>();
  const sets: [string, string][] = [];
  const source: TrustSource = {
    get: (cwd) => {
      const own = record.get(cwd);
      const repo = record.get(repoRoot);
      const level = own ?? repo ?? "unknown";
      return Promise.resolve({
        cwd,
        level,
        decided: level !== "unknown",
        ...(own === undefined && repo !== undefined && cwd !== repoRoot ? { via: repoRoot } : {}),
        repo: { root: repoRoot, worktree: cwd === worktree },
      });
    },
    set: (cwd, level) => {
      sets.push([cwd, level]);
      if (level === "unknown") record.delete(cwd);
      else record.set(cwd, level);
      return Promise.resolve({ cwd, level });
    },
  };
  return { source, sets, record };
}

let latest: ReturnType<typeof useFolderTrustAsk> | undefined;
function Chat(props: { trust: TrustSource; sessionId: string; cwd: string }) {
  latest = useFolderTrustAsk(props.trust, { sessionId: props.sessionId, cwd: props.cwd, prompts: 0 }, true, false);
  return null;
}
const open = (trust: TrustSource, sessionId: string, cwd: string) =>
  act(async () => root.render(<Chat trust={trust} sessionId={sessionId} cwd={cwd} />));

test("acpmux's via and repo are read from its reply", () => {
  expect(
    readTrust({
      cwd: worktree,
      level: "trusted",
      decided: true,
      via: repoRoot,
      repo: { root: repoRoot, worktree: true },
    }),
  ).toEqual({
    cwd: worktree,
    level: "trusted",
    decided: true,
    via: repoRoot,
    repo: { root: repoRoot, worktree: true },
  });
  // An older acpmux sends neither; a null repo is none.
  expect(readTrust({ cwd: worktree, level: "unknown", via: null, repo: null })).toEqual({
    cwd: worktree,
    level: "unknown",
  });
});

test("Trust repo in one worktree answers the next worktree with no question, and Undo forgets the repo", async () => {
  const { source, sets } = daemon();
  await open(source, "chat-main", `${repoRoot}/packages/fetch`);
  expect(latest!.ask).toMatchObject({ state: "ask", repo: { root: repoRoot } });
  await act(async () => latest!.trustRepo());
  expect(sets).toEqual([[repoRoot, "trusted"]]);
  expect(latest!.trusted).toBe(true);

  // A worktree cmux made for the next chat: trusted via the repository, nothing asked.
  await open(source, "chat-worktree", worktree);
  expect(latest!.ask).toBeUndefined();
  expect(latest!.trusted).toBe(true);
  expect(latest!.blocked).toBeUndefined();
  expect(latest!.scope).toMatchObject({ cwd: worktree, via: repoRoot });

  // Undo (the Access grant's ×) forgets the answer where it was made: the repository.
  await act(async () => latest!.undo());
  expect(sets.at(-1)).toEqual([repoRoot, "unknown"]);
  expect(latest!.ask?.state).toBe("ask");
});

test("Only this folder records the folder, and Not now the repository", async () => {
  const { source, sets } = daemon();
  await open(source, "chat-only", worktree);
  await act(async () => latest!.trust());
  expect(sets).toEqual([[worktree, "trusted"]]);
  const other = daemon();
  await open(other.source, "chat-decline", worktree);
  await act(async () => latest!.distrust());
  expect(other.sets).toEqual([[repoRoot, "untrusted"]]);
  expect(latest!.blocked?.reason).toBe("trust.notTrustedNoPrompts");
});

const noop = () => undefined;
const render = (
  ask: Parameters<typeof TrustAsk>[0]["ask"],
  onTrustRepo: () => void = noop,
  { onTrust = noop, answers = true }: { onTrust?: () => void; answers?: boolean } = {},
) =>
  act(async () =>
    root.render(
      <TrustAsk
        ask={ask}
        agent="Claude Code"
        onTrust={onTrust}
        onTrustRepo={onTrustRepo}
        onDistrust={noop}
        onUndo={noop}
        answers={answers}
      />,
    ),
  );
const buttons = () => [...host.querySelectorAll("button")].map((button) => button.textContent);

test("the question names the repo, says what trusting allows and what Not now means", async () => {
  let trustedRepo = 0;
  await render({ cwd: worktree, repo: { root: repoRoot, worktree: true }, state: "ask" }, () => (trustedRepo += 1));
  expect(host.querySelector(".acpmux-trust-ask-text")!.textContent).toBe("Trust the atlas-web repo?");
  const detail = host.querySelector(".acpmux-trust-ask-detail")!.textContent!;
  expect(detail).toContain("run commands and edit files");
  expect(detail).toContain("all its worktrees");
  expect(detail).toContain("hooks, MCP servers and settings");
  expect(detail).toContain("Not now: Claude Code won't run here");
  // The common case first and marked primary.
  expect(buttons()).toEqual(["Trust repo", "Only this folder", "Not now"]);
  expect(host.querySelector("button.acpmux-trust-ask-primary")!.textContent).toBe("Trust repo");
  await act(async () => (host.querySelector("button.acpmux-trust-ask-primary") as HTMLButtonElement).click());
  expect(trustedRepo).toBe(1);
});

test("the repository's own folder has no separate Only this folder; a plain folder has Trust folder", async () => {
  await render({ cwd: repoRoot, repo: { root: repoRoot, worktree: false }, state: "ask" });
  expect(buttons()).toEqual(["Trust repo", "Not now"]);
  await render({ cwd: "/Users/you/Downloads/thing", state: "ask" });
  expect(host.querySelector(".acpmux-trust-ask-text")!.textContent).toBe("Trust thing?");
  expect(buttons()).toEqual(["Trust folder", "Not now"]);
});

test("a worktree answered by its repository keeps Trust and Undo after Not now", async () => {
  await render({
    cwd: worktree,
    repo: { root: repoRoot, worktree: true },
    via: repoRoot,
    state: "decided",
    level: "trusted",
  });
  expect(host.querySelector(".acpmux-trust-ask-text")!.textContent).toBe("Trusted via repo atlas-web");
  expect(buttons()).toEqual(["Undo"]);
  let trustRepo = 0;
  await render(
    {
      cwd: worktree,
      repo: { root: repoRoot, worktree: true },
      via: repoRoot,
      state: "decided",
      level: "untrusted",
    },
    () => (trustRepo += 1),
  );
  expect(host.querySelector(".acpmux-trust-ask-text")!.textContent).toBe(
    "Not trusted: Claude Code won't run in the atlas-web repo",
  );
  expect(buttons()).toEqual(["Trust repo", "Undo"]);
  await act(async () => (host.querySelector(".acpmux-trust-ask-primary") as HTMLButtonElement).click());
  expect(trustRepo).toBe(1);
});

test("after Not now, Trust records where that answer lives: the repository only when it holds it", async () => {
  // acpmux reads the folder's own answer, then its worktree's, then its repository's (trust.rs):
  // Trust repo would leave a folder's or worktree's own Not now in force.
  const counts = { repo: 0, folder: 0 };
  const handlers = [() => (counts.repo += 1), { onTrust: () => (counts.folder += 1) }] as const;
  const inWorktree = `${worktree}/packages/api`;
  await render(
    { cwd: inWorktree, repo: { root: repoRoot, worktree: true }, via: worktree, state: "decided", level: "untrusted" },
    ...handlers,
  );
  expect(buttons()).toEqual(["Trust folder", "Undo"]);
  await act(async () => (host.querySelector(".acpmux-trust-ask-primary") as HTMLButtonElement).click());
  await render(
    { cwd: worktree, repo: { root: repoRoot, worktree: true }, state: "decided", level: "untrusted" },
    ...handlers,
  );
  expect(buttons()).toEqual(["Trust folder", "Undo"]);
  await act(async () => (host.querySelector(".acpmux-trust-ask-primary") as HTMLButtonElement).click());
  expect(counts).toEqual({ repo: 0, folder: 2 });
});

test("a chat whose host keeps its answer offers no Trust after Not now", async () => {
  await render(
    { cwd: worktree, repo: { root: repoRoot, worktree: true }, via: repoRoot, state: "decided", level: "untrusted" },
    noop,
    { answers: false },
  );
  // Undo would send an answer the host rejects, and that failure would offer Trust: neither works.
  expect(buttons()).toEqual([]);
});

test("a chat whose host keeps its answer offers no Trust or Not now when an answer failed", async () => {
  for (const ask of [
    { cwd: worktree, repo: { root: repoRoot, worktree: true }, state: "failed" as const },
    { cwd: "/Users/you/Downloads/thing", state: "failed" as const },
    { cwd: worktree, repo: { root: repoRoot, worktree: true }, state: "ask" as const },
  ]) {
    await render(ask, noop, { answers: false });
    expect(buttons()).toEqual([]);
  }
});

test("the Access grant names where the answer lives: the repository, not the chat's private folder", () => {
  const t = translatorFor("en");
  expect(trustedLabel(t, { cwd: worktree, repo: { root: repoRoot, worktree: true }, via: repoRoot })).toBe(
    "Trusted via repo atlas-web",
  );
  expect(trustedLabel(t, { cwd: repoRoot, repo: { root: repoRoot, worktree: false } })).toBe(
    "Trusted the atlas-web repo and its worktrees",
  );
  expect(trustedLabel(t, { cwd: "/Users/you/Downloads/thing" })).toBe("Trusted thing");
  // An auto-trust rule (or an agent's own level) trusted the repository's folder: no answer for
  // the repository exists, so the grant names the folder.
  expect(trustedLabel(t, { cwd: repoRoot, repo: { root: repoRoot, worktree: false }, recorded: false })).toBe(
    "Trusted atlas-web",
  );
});
