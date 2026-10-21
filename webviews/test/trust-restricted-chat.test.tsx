// Leo, 2026-10-21 (no dead ends): Not now on a folder's trust question used to leave a chat that
// could never run. With acpmux's restricted chats on (`agents.trust.restrictedChats`, acpmux
// `hub/restricted.rs`), a Claude Code chat there runs restricted: the pane keeps Send on, says
// what the chat runs without, and keeps Trust repo / Trust folder in reach. With them off the
// pane is as before: Not now holds Send with its reason.
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
const { readTrust, restrictedChat } = await import("../src/agent-session/acpmux/folderTrust");
const { TrustAsk } = await import("../src/agent-session/acpmux/TrustAsk");
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

const cwd = "/Users/you/Downloads/strange-repo";
const RESTRICTED = "Restricted: no project settings, hooks or MCP; asks before every tool";

/// acpmux in miniature: one folder's record, and whether it opens restricted chats.
function daemon(restrictedChats: boolean) {
  let level = "unknown";
  const source: TrustSource = {
    get: (asked) =>
      Promise.resolve({
        cwd: asked,
        level,
        decided: level !== "unknown",
        ...(restrictedChats ? { restrictedChats: true } : {}),
      }),
    set: (_, next) => {
      level = next;
      return Promise.resolve({});
    },
  };
  return source;
}

let latest: ReturnType<typeof useFolderTrustAsk> | undefined;
function Chat(props: { trust: TrustSource; sessionId: string; family?: string; restricted?: boolean }) {
  latest = useFolderTrustAsk(
    props.trust,
    {
      sessionId: props.sessionId,
      cwd,
      prompts: 0,
      ...(props.family ? { family: props.family } : {}),
      ...(props.restricted ? { restricted: true } : {}),
    },
    true,
    false,
  );
  return null;
}
const open = (trust: TrustSource, sessionId: string, extra: { family?: string; restricted?: boolean } = {}) =>
  act(async () => root.render(<Chat trust={trust} sessionId={sessionId} {...extra} />));

test("acpmux's restrictedChats is read from its reply, and only Claude Code's chats run restricted", () => {
  const trust = readTrust({ cwd, level: "untrusted", decided: true, restrictedChats: true })!;
  expect(trust.restrictedChats).toBe(true);
  expect(readTrust({ cwd, level: "untrusted", restrictedChats: "yes" })!.restrictedChats).toBeUndefined();
  expect(restrictedChat(trust, "claude")).toBe(true);
  expect(restrictedChat(trust)).toBe(true);
  expect(restrictedChat(trust, "codex")).toBe(false);
  expect(restrictedChat({ cwd, level: "untrusted" }, "claude")).toBe(false);
});

test("with restricted chats off, Not now still holds Send as before", async () => {
  await open(daemon(false), "off");
  await act(async () => latest!.distrust());
  expect(latest!.restricted).toBe(false);
  expect(latest!.blocked?.reason).toBe("trust.notTrustedNoPrompts");
  expect(latest!.holdsAsks).toBe(true);
  expect(latest!.ask).toEqual({ cwd, state: "decided", level: "untrusted" });
});

test("with restricted chats on, Not now leaves a chat that sends, restricted", async () => {
  await open(daemon(true), "on", { family: "claude" });
  expect(latest!.ask?.state).toBe("ask");
  await act(async () => latest!.distrust());
  expect(latest!.restricted).toBe(true);
  expect(latest!.blocked).toBeUndefined();
  expect(latest!.holdsAsks).toBe(false);
  expect(latest!.ask).toMatchObject({ state: "decided", level: "untrusted", restricted: true });
  // A chat opened later in the folder reads it the same way.
  const folder = daemon(true);
  await open(folder, "later", { family: "claude" });
  await act(async () => latest!.distrust());
  await open(folder, "again", { family: "claude" });
  expect(latest!.ask).toMatchObject({ state: "decided", level: "untrusted", restricted: true });
  expect(latest!.restricted).toBe(true);
});

test("another agent's chat keeps the refusal; acpmux's own restricted mark and refusal win", async () => {
  await open(daemon(true), "codex", { family: "codex" });
  await act(async () => latest!.distrust());
  expect(latest!.restricted).toBe(false);
  expect(latest!.blocked?.reason).toBe("trust.notTrustedNoPrompts");

  // acpmux says the chat is restricted (its summary): it sends even before a read says so.
  await open(daemon(false), "marked", { family: "claude", restricted: true });
  await act(async () => latest!.distrust());
  expect(latest!.restricted).toBe(true);
  expect(latest!.blocked).toBeUndefined();

  // acpmux refused the chat for Don't trust after all: it is not a restricted chat.
  await open(daemon(true), "refused", { family: "claude" });
  await act(async () => latest!.distrust());
  expect(latest!.restricted).toBe(true);
  await act(async () => void latest!.refused({ reason: "trust.untrusted", cwd }));
  expect(latest!.restricted).toBe(false);
});

const noop = () => undefined;
const buttons = () => [...host.querySelectorAll("button")].map((button) => button.textContent);

test("the restricted chat says what it runs without and keeps Trust in reach", async () => {
  let trusted = 0;
  let trustedRepo = 0;
  const render = (ask: Parameters<typeof TrustAsk>[0]["ask"]) =>
    act(async () =>
      root.render(
        <TrustAsk
          ask={ask}
          agent="Claude Code"
          onTrust={() => (trusted += 1)}
          onTrustRepo={() => (trustedRepo += 1)}
          onDistrust={noop}
          onUndo={noop}
        />,
      ),
    );
  await render({ cwd, state: "decided", level: "untrusted", restricted: true });
  expect(host.querySelector(".acpmux-trust-ask-text")!.textContent).toBe(RESTRICTED);
  expect(host.querySelector("[data-restricted]")).not.toBeNull();
  expect(buttons()).toEqual(["Trust folder", "Undo"]);
  await act(async () => (host.querySelector("button.acpmux-trust-ask-primary") as HTMLButtonElement).click());
  expect(trusted).toBe(1);

  const repoRoot = "/Users/you/Projects/atlas-web";
  await render({
    cwd: `${repoRoot}/packages/fetch`,
    repo: { root: repoRoot, worktree: false },
    via: repoRoot,
    state: "decided",
    level: "untrusted",
    restricted: true,
  });
  expect(buttons()).toEqual(["Trust repo", "Undo"]);
  await act(async () => (host.querySelector("button.acpmux-trust-ask-primary") as HTMLButtonElement).click());
  expect(trustedRepo).toBe(1);

  // Without the restriction the receipt is the old dead end's.
  await render({ cwd, state: "decided", level: "untrusted" });
  expect(host.querySelector("[data-restricted]")).toBeNull();
  expect(buttons()).toEqual(["Undo"]);
});
