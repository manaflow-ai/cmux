// Leo, 2026-10-21: "you see claude at the top and it literally will 'think' aka wait forever until you
// click 'trust'". While the folder's trust question waits on the person, the turn's line names what
// it waits for ("Waiting for you to trust atlas-web") and points at the question: a click brings the
// question into view and onto its primary answer.
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
// jsdom lays nothing out, so it has no scrollIntoView: count the calls instead.
const scrolled: Element[] = [];
dom.window.HTMLElement.prototype.scrollIntoView = function (this: Element) {
  scrolled.push(this);
};

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { TrustAsk, trustAskName } = await import("../src/agent-session/acpmux/TrustAsk");
const { Thinking } = await import("../src/agent-session/acpmux/conversation/Thinking");
const { WorkingFor } = await import("../src/agent-session/acpmux/conversation/WorkingFor");
const { WaitingProvider } = await import("../src/agent-session/acpmux/conversation/WaitingLabel");
const { translate } = await import("../src/agent-session/acpmux/i18n");
type FolderTrustAsk = import("../src/agent-session/acpmux/useFolderTrustAsk").FolderTrustAsk;
type AcpmuxRow = import("../src/agent-session/acpmux/model").AcpmuxRow;

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
const worktree: FolderTrustAsk = {
  cwd: "/Users/you/.cmux/worktrees/atlas-web/fix-retry",
  repo: { root: repoRoot, worktree: true },
  state: "ask",
};
const noop = () => undefined;

/// The pane in miniature: the turn's line in the transcript, the trust question on the composer.
const pane = (line: React.ReactElement, ask: FolderTrustAsk = worktree) =>
  act(async () =>
    root.render(
      <>
        <WaitingProvider on="trust" trust={trustAskName(ask)}>
          {line}
        </WaitingProvider>
        <TrustAsk ask={ask} agent="Claude Code" onTrust={noop} onTrustRepo={noop} onDistrust={noop} onUndo={noop} />
      </>,
    ),
  );

test("the trust question is named by what it trusts: the repo, else the folder, never a private folder", () => {
  expect(trustAskName(worktree)).toBe("atlas-web");
  expect(trustAskName({ cwd: "/Users/you/Downloads/thing" })).toBe("thing");
  expect(trustAskName({ cwd: "/Users/you/Library/Application Support/cmux/agent-home/ws-1" })).toBeUndefined();
});

test("the line names what it waits for, never Thinking, and points at the question", async () => {
  await pane(<Thinking since={0} now={() => 5_000} />);
  const show = host.querySelector<HTMLButtonElement>(".cv-waiting button.cv-waiting__show")!;
  expect(show.textContent).toBe("Waiting for you to trust atlas-web");
  expect(host.textContent).not.toContain(translate("thinking"));
  expect(host.querySelector(".cv-worked__time")).toBeNull();
  scrolled.length = 0;
  await act(async () => show.click());
  const card = host.querySelector(".acpmux-trust-ask[data-asking]")!;
  expect(scrolled).toEqual([card]);
  expect(dom.window.document.activeElement?.textContent).toBe("Trust repo");
});

test("the running turn's line says the same", async () => {
  const row = { id: "working-1", version: 1, at: 0, kind: "working", thinkingNow: true } as AcpmuxRow;
  await pane(<WorkingFor row={row} now={() => 5_000} />);
  expect(host.querySelector(".cv-waiting__show")!.textContent).toBe("Waiting for you to trust atlas-web");
  expect(host.textContent).not.toContain(translate("thinking"));
});

test("a folder outside a repo is named by the folder; a private folder says this folder", async () => {
  await pane(<Thinking />, { cwd: "/Users/you/Downloads/thing", state: "ask" });
  expect(host.querySelector(".cv-waiting__show")!.textContent).toBe("Waiting for you to trust thing");
  await pane(<Thinking />, { cwd: "/Users/you/Library/Application Support/cmux/agent-home/ws-1", state: "ask" });
  expect(host.querySelector(".cv-waiting__show")!.textContent).toBe("Waiting for you to trust this folder");
});
