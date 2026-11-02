// l10n-allow-file: test fixture folders, branches and agent names, not shipped UI.
// Session Info for a subagent (Leo, 2026-10-21: "subagent should have its own instance of it like
// it might have different env worktree context bg tasks outputs and diffs etc"): while the pane shows
// a subagent's own view, the panel lists that subagent's environment, context, background tasks and
// outputs, read from its own rows, never merged with the chat's; the chat's panel keeps its own.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { SessionInfo, useSessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { resetSessionInfoState, setSessionInfoOpen } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { SubagentScope } from "../src/agent-session/acpmux/session-info/subagentScope";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { activity, tool } from "../src/gallery/fixtures/acpmux";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const CHAT: Summary = {
  sessionId: "chat-1",
  cwd: "/Users/you/src/atlas-web",
  branch: "feat/retries",
  usage: { used: 90_000, size: 200_000 },
  mcpServers: [{ name: "github", status: "connected" }],
};
const TREE = "/Users/you/src/atlas-web/.claude/worktrees/agent-a3f9c2";
const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "chat-1/toolu_1",
  parent: null,
  name: "Fix the timeouts",
  state: "running",
  startedAt: 1,
  ...fields,
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  setHeaderState({ inspector: true });
  setSessionInfoOpen(true);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => resetSessionInfoState());

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

const treeRows: AcpmuxRow[] = [
  activity(
    [
      tool("Edit fetch.ts", "edit", "completed", {
        diffs: [{ path: `${TREE}/src/net/fetch.ts`, oldText: "a\n", newText: "b\n" }],
      }),
      tool("Run tests", "execute", "in_progress", {
        command: "bun test --watch",
        inputSummary: JSON.stringify({ command: "bun test --watch", run_in_background: true }),
      }),
    ],
    2,
  ),
];

function SubagentPane({
  snapshot,
  subagent,
  onOpenOutput,
}: {
  snapshot: AcpmuxSnapshot;
  subagent: SubagentScope;
  onOpenOutput: (path: string) => void;
}) {
  const sessionInfo = useSessionInfo({
    snapshot,
    repository: "acme/atlas-web",
    subagent,
    onOpenOutput,
    onOpenSourceFile: onOpenOutput,
  });
  return <>{sessionInfo.panel}</>;
}

test("the subagent's panel lists its worktree, its tokens and its own edits; the chat's lists its own", async () => {
  const container = installDom();
  root = createRoot(container);
  const sub = agent({ worktree: { path: TREE, branch: "worktree-agent-a3f9c2" }, tokens: 48_200, toolUses: 14 });
  const chatRows: AcpmuxRow[] = [
    activity(
      [
        tool("Edit README.md", "edit", "completed", {
          diffs: [{ path: `${CHAT.cwd}/README.md`, oldText: "a\n", newText: "b\n" }],
        }),
      ],
      5,
    ),
  ];
  const opened: string[] = [];
  const snapshot: AcpmuxSnapshot = {
    type: "snapshot",
    protocolVersion: 1,
    connection: "connected",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
    rows: [],
    sessions: [],
    summary: CHAT,
  };
  const scope: SubagentScope = {
    agent: sub,
    rows: [
      ...treeRows,
      activity([tool("Read src/config.ts", "read", "completed", { locations: [{ path: "src/config.ts" }] })], 9),
    ],
    agents: [],
    parent: CHAT.sessionId,
  };
  await act(async () =>
    root!.render(<SubagentPane snapshot={snapshot} subagent={scope} onOpenOutput={(path) => opened.push(path)} />),
  );
  const text = () => container.textContent ?? "";
  expect(text()).toContain("agent-a3f9c2");
  expect(text()).toContain("worktree-agent-a3f9c2");
  expect(text()).not.toContain("feat/retries");
  expect(text()).toContain("14 tool uses");
  expect(text()).toContain("fetch.ts");
  expect(text()).not.toContain("README.md");
  expect(text()).toContain("bun test --watch");
  expect(text()).not.toContain("github");
  await act(async () => container.querySelector<HTMLButtonElement>('ul[data-section="sources"] button')!.click());
  expect(opened).toEqual([`${TREE}/src/config.ts`]);
  const remote = { ...scope, agent: { ...scope.agent, host: "build.example" } };
  await act(async () =>
    root!.render(<SubagentPane snapshot={snapshot} subagent={remote} onOpenOutput={(path) => opened.push(path)} />),
  );
  expect(container.querySelector('ul[data-section="sources"] button')).toBeNull();
  expect(container.querySelector('ul[data-section="sources"]')?.textContent).toContain("src/config.ts");

  await act(async () =>
    root!.render(
      <SessionInfo
        summary={CHAT}
        rows={chatRows}
        made={sessionSummary(chatRows, "acme/atlas-web", CHAT.cwd)}
        agents={[sub]}
      />,
    ),
  );
  expect(text()).toContain("feat/retries");
  expect(text()).toContain("README.md");
  expect(text()).not.toContain("agent-a3f9c2");
  // The chat's Subagents card lists the subagent.
  expect(container.querySelector('[data-section="subagents"]')?.textContent).toContain("Fix the timeouts");
});
