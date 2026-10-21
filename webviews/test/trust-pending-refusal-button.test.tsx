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
  return buttons.find((button) => button.textContent === "Trust folder");
}

async function refusedThenTrusted(read: () => Promise<unknown>, cwd: string, sessionId: string) {
  const trust = source(read);
  await act(async () => root.render(<Pane trust={trust.source} sessionId={sessionId} cwd={cwd} />));
  let resent = 0;
  await act(async () => {
    shown!.refused(pending(cwd), () => {
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
  expect(trust.sets).toEqual([[cwd, "trusted"]]);
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
