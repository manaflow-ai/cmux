// Leo 2026-10-21 (P0): acpmux refused a send with `trust.pending` ("answer the trust question for
// the folder first") and the pane only said "Not sent: trust.pending". The refusal re-read the
// folder's trust, and a read that disagreed with the gate (an auto-trust rule says trusted, a
// read that timed out or failed) left no question on screen, so nothing could clear the gate.
// acpmux's refusal is the authority: it always shows the folder's Trust button, and Trust answers
// acpmux's trust question for that folder and sends the refused prompt again.
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

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useFolderTrustAsk } = await import("../src/agent-session/acpmux/useFolderTrustAsk");
const { TrustAsk } = await import("../src/agent-session/acpmux/TrustAsk");
type Hook = ReturnType<typeof useFolderTrustAsk>;

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

/// A trust source whose reads answer `read` (or fail), recording every answer saved.
function source(read: () => Promise<unknown>) {
  const sets: [string, string][] = [];
  return {
    sets,
    source: {
      get: () => read(),
      set: async (cwd: string, level: string) => {
        sets.push([cwd, level]);
      },
    },
  };
}

let shown: Hook | undefined;
/// The pane's bottom stack as App.tsx draws it: the hook, and its question when it has one.
function Pane({
  trust,
  sessionId,
  cwd,
}: {
  trust: ReturnType<typeof source>["source"];
  sessionId: string;
  cwd: string;
}) {
  shown = useFolderTrustAsk(trust, { sessionId, cwd, family: "claude", prompts: 1 });
  const ask = shown.ask;
  return ask && (ask.state !== "decided" || ask.level === "untrusted") ? (
    <TrustAsk
      ask={ask}
      agent="Claude Code"
      onTrust={shown.trust}
      onTrustRepo={shown.trustRepo}
      onDistrust={shown.distrust}
      onUndo={shown.undo}
    />
  ) : null;
}

const pending = (cwd: string) =>
  Object.assign(new Error(`trust.pending: answer the trust question for the folder first (${cwd})`), {
    reason: "trust.pending",
    cwd,
  });

function trustButton() {
  const buttons = [...host.querySelectorAll("button")];
  return buttons.find((button) => button.classList.contains("acpmux-trust-ask-primary"));
}

/// `named`: the folder acpmux's refusal names, which can be another spelling of the chat's `cwd`.
async function refusedThenTrusted(read: () => Promise<unknown>, cwd: string, sessionId: string, named = cwd) {
  const trust = source(read);
  await act(async () => root.render(<Pane trust={trust.source} sessionId={sessionId} cwd={cwd} />));
  let resent = 0;
  await act(async () => {
    shown!.refused(pending(named), () => {
      resent += 1;
    });
  });
  // The read after the refusal has answered: the question is on screen, Send waits on it.
  const button = trustButton();
  const visible = button !== undefined;
  expect(visible).toBe(true);
  expect(shown!.blocked).toEqual({ reason: "trust.answerFirst", shownAbove: true });
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  expect(trust.sets).toEqual([[named, "trusted"]]);
  expect(resent).toBe(1);
  expect(shown!.blocked).toBeUndefined();
}

test("trust.pending shows Trust folder when the folder reads as trusted by a rule", async () => {
  const cwd = "/Users/you/src/rule-trusted";
  await refusedThenTrusted(async () => ({ cwd, level: "trusted", decided: false, auto: "root" }), cwd, "chat-rule");
});

test("trust.pending shows Trust folder when the folder's trust can't be read", async () => {
  const cwd = "/Users/you/src/unreadable";
  await refusedThenTrusted(
    async () => {
      throw new Error("native.timed_out");
    },
    cwd,
    "chat-unreadable",
  );
});

test("trust.pending for another spelling of the folder trusts the folder acpmux named", async () => {
  const cwd = "/Users/you/src/link";
  await refusedThenTrusted(async () => ({ cwd, level: "unknown" }), cwd, "chat-link", "/Users/you/src/real");
});

test("a chat keeps its trust.pending question and its own prompt across a chat switch", async () => {
  const cwd = "/Users/you/src/shared";
  const trust = source(async () => ({ cwd, level: "trusted", decided: false, auto: "root" }));
  const sent: string[] = [];
  const show = (sessionId: string) =>
    act(async () => root.render(<Pane trust={trust.source} sessionId={sessionId} cwd={cwd} />));
  await show("chat-a");
  await act(async () => {
    shown!.refused(pending(cwd), () => sent.push("a"));
  });
  // Another chat in the same folder, which acpmux never refused: no question there.
  await show("chat-b");
  const askedInB = trustButton() !== undefined;
  expect(askedInB).toBe(false);
  await show("chat-a");
  const button = trustButton();
  const askedInA = button !== undefined;
  expect(askedInA).toBe(true);
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  expect(sent).toEqual(["a"]);
});

test("Trust invalidates a pending read for the chat cwd when refusal names another cwd", async () => {
  const chatCwd = "/Users/you/src/link-pending";
  let reads = 0;
  let resolveStale: ((value: unknown) => void) | undefined;
  const trust = source(() => {
    reads += 1;
    if (reads === 1) return Promise.resolve({ cwd: chatCwd, level: "trusted", decided: false, auto: "root" });
    if (reads === 2)
      return new Promise((resolve) => {
        resolveStale = resolve;
      });
    return Promise.resolve({ cwd: chatCwd, level: "trusted", decided: false, auto: "root" });
  });
  const show = (sessionId: string) =>
    act(async () => root.render(<Pane trust={trust.source} sessionId={sessionId} cwd={chatCwd} />));

  await show("chat-pending-a");
  await act(async () => {
    shown!.refused(pending("/Users/you/src/real-pending"), () => undefined);
  });
  // Switching away and back leaves the alternate-cwd refresh in flight for this chat.
  await show("chat-pending-b");
  await show("chat-pending-a");
  const button = trustButton();
  expect(button).toBeDefined();
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });

  // The stale refresh reports the old untrusted state after Trust. It must be ignored.
  await act(async () => {
    resolveStale!({ cwd: chatCwd, level: "unknown" });
    await Promise.resolve();
  });
  expect(trustButton()).toBeUndefined();
  expect(shown!.blocked).toBeUndefined();
});
