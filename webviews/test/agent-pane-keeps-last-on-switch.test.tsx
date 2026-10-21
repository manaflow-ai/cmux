// Leo, 2026-10-19: "identify and solve all situations where that kind of thing could occur". Each
// piece of the agent pane read per chat, folder or scope drew nothing (or a stand-in) on a switch or
// a reload until its read came back, then the real value: the edited-files counts, the worktree
// pill, the changes list, an empty chat's hero. Each now draws what it last read from the first
// committed render and the read only refreshes it. The probes record committed renders (layout
// effects run before paint); a render React throws away is never drawn.
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
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const React = await import("react");
const { act } = React;
const { createRoot } = await import("react-dom/client");
const { useTurnCheckpoints } = await import("../src/agent-session/acpmux/changes/useTurnCheckpoints");
const { useWorktree } = await import("../src/agent-session/acpmux/header/WorktreePill");
const { useScopeChanges } = await import("../src/agent-session/acpmux/changes/useScopeChanges");
const { isNewChat } = await import("../src/agent-session/acpmux/EmptyState");

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const never = () => new Promise<never>(() => {});

test("back on a chat, its edited-files checkpoints draw from the first render", async () => {
  const answered = new Set<string>();
  const read = ({ rowId }: { rowId: string }) => {
    if (answered.has(rowId)) return never();
    answered.add(rowId);
    return Promise.resolve({ checkpoint_id: `cp-${rowId}`, complete: true, diff: { files: [] } });
  };
  const seen: string[] = [];
  function Probe(props: { sessionId: string; rowId: string }) {
    const checkpoints = useTurnCheckpoints(read, props.sessionId);
    React.useEffect(() => checkpoints.request(props.rowId));
    React.useLayoutEffect(() => {
      seen.push(`${props.sessionId}:${checkpoints.get(props.rowId)?.state}`);
    });
    return null;
  }
  await act(async () => root.render(<Probe sessionId="chat-a" rowId="row-a" />));
  await settle();
  expect(seen.at(-1)).toBe("chat-a:loaded");
  await act(async () => root.render(<Probe sessionId="chat-b" rowId="row-b" />));
  await settle();
  seen.length = 0;
  await act(async () => root.render(<Probe sessionId="chat-a" rowId="row-a" />));
  await settle();
  expect(seen.filter((state) => state !== "chat-a:loaded")).toEqual([]);
});

test("back in a folder, its worktree pill draws from the first render", async () => {
  const read = new Set<string>();
  const readStatus = (cwd: string) => {
    if (read.has(cwd)) return never();
    read.add(cwd);
    return Promise.resolve({ branch: `feature-${cwd.length}`, base: "main", worktree: { main_root: "/repo" } });
  };
  const seen: (string | undefined)[] = [];
  function Probe(props: { folder: string }) {
    const worktree = useWorktree(props.folder, readStatus);
    React.useLayoutEffect(() => {
      seen.push(worktree?.branch);
    });
    return null;
  }
  await act(async () => root.render(<Probe folder="/repo-wt-a" />));
  await settle();
  const branch = seen.at(-1);
  expect(branch).toBeDefined();
  await act(async () => root.render(<Probe folder="/repo-b" />));
  await settle();
  seen.length = 0;
  await act(async () => root.render(<Probe folder="/repo-wt-a" />));
  await settle();
  // Every committed render names the branch (toEqual would take [undefined] for []).
  expect(seen.filter((shown) => shown !== branch)).toHaveLength(0);
});

test("a reload of the changes on screen keeps them until the new answer", async () => {
  let reads = 0;
  const source = {
    diff: () =>
      reads++ === 0
        ? Promise.resolve({
            scope: "uncommitted",
            files: [{ path: "a.ts", status: "modified", additions: 1, deletions: 0 }],
          })
        : never(),
  } as unknown as Parameters<typeof useScopeChanges>[0];
  const seen: string[] = [];
  let retry: () => void = () => {};
  function Probe() {
    const changes = useScopeChanges(source, "uncommitted");
    retry = changes.retry;
    React.useLayoutEffect(() => {
      seen.push(changes.load.state);
    });
    return null;
  }
  await act(async () => root.render(<Probe />));
  await settle();
  expect(seen.at(-1)).toBe("loaded");
  seen.length = 0;
  // A stage, unstage or commit reads the scope again.
  await act(async () => retry());
  await settle();
  expect(seen.filter((state) => state !== "loaded")).toEqual([]);
});

test("a chat with no turns keeps its hero while the pane connects", () => {
  const snapshot = {
    sessionId: "chat-empty",
    summary: { sessionId: "chat-empty", turnCount: 0 },
    rows: [],
    queue: [],
    isWorking: false,
    connection: "connecting",
  } as unknown as Parameters<typeof isNewChat>[0];
  expect(isNewChat(snapshot)).toBe(true);
  expect(isNewChat({ ...snapshot, connection: "disconnected" })).toBe(true);
  expect(isNewChat({ ...snapshot, connection: "failed" })).toBe(false);
});
