// l10n-allow-file: test fixtures, not shipped UI.
// Leo, 2026-11-21: "workspace switch, opening a recent workspace, chat switch and restart reach a
// settled page (zero layout shift after first paint, streaming included) within 2x of a derived
// bound." The turn checkpoints and the process registry each stored the new chat's empty state in
// an effect on a chat switch, though the render already read it, so each rendered the whole pane a
// second time before the switch's first frame (bench/settled-page.bench.ts, chat_switch).
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ProcessSource } from "../src/agent-session/acpmux/session-info/processes";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useProcessRegistry } = await import("../src/agent-session/acpmux/session-info/processes");
const { useTurnCheckpoints } = await import("../src/agent-session/acpmux/changes/useTurnCheckpoints");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

test("a chat switch renders the process registry once", async () => {
  const replies: ((reply: unknown) => void)[] = [];
  const source: ProcessSource = {
    listProcesses: () => new Promise((resolve) => replies.push(resolve)),
    watchProcesses: () => () => {},
  };
  let renders = 0;
  let count = -1;
  function View({ sessionId }: { sessionId: string }) {
    renders += 1;
    count = useProcessRegistry(source, sessionId, true).processes.length;
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<View sessionId="chat-a" />));
    await act(async () =>
      replies.shift()!({
        processes: [{ id: "chat-a/1", sessionId: "chat-a", command: "sleep", state: "running", startedAt: 1 }],
      }),
    );
    expect(count).toBe(1);
    const before = renders;
    await act(async () => root.render(<View sessionId="chat-b" />));
    // The switch's own render; chat B's listing has not answered.
    expect(renders - before).toBe(1);
    expect(count).toBe(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat switch renders the turn checkpoints once, and a visit back reads its turns again", async () => {
  const reads: string[] = [];
  const read = async ({ rowId }: { rowId: string }) => {
    reads.push(rowId);
    return new Promise<unknown>(() => {});
  };
  let renders = 0;
  let checkpoints: ReturnType<typeof useTurnCheckpoints> | undefined;
  function View({ sessionId }: { sessionId: string }) {
    renders += 1;
    checkpoints = useTurnCheckpoints(read, sessionId);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<View sessionId="switch-a" />));
    await act(async () => checkpoints!.request("turn-1"));
    expect(checkpoints!.get("turn-1")).toEqual({ state: "loading" });
    const before = renders;
    await act(async () => root.render(<View sessionId="switch-b" />));
    expect(renders - before).toBe(1);
    expect(checkpoints!.get("turn-1")).toBeUndefined();
    // Back on chat A, the read left unanswered is not drawn as loading: the turn is asked again.
    await act(async () => root.render(<View sessionId="switch-a" />));
    expect(checkpoints!.get("turn-1")).toBeUndefined();
    await act(async () => checkpoints!.request("turn-1"));
    expect(reads).toEqual(["turn-1", "turn-1"]);
    expect(checkpoints!.get("turn-1")).toEqual({ state: "loading" });
  } finally {
    await act(async () => root.unmount());
  }
});
