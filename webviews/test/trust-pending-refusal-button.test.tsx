// Leo 2026-10-21 (P0): acpmux refused a send with `trust.pending` ("answer the trust question for
// the folder first") and the pane only said "Not sent: trust.pending". The refusal re-read the
// folder's trust, and a read that disagreed with the gate (an auto-trust rule says trusted, a
// read that timed out or failed) left no question on screen, so nothing could clear the gate.
// acpmux's refusal is the authority: it always shows the folder's Trust button, and Trust answers
// acpmux's trust question for that folder and sends the refused prompt again.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";

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
const { failedRowTrustRetry } = await import("../src/agent-session/acpmux/failedRowTrustRetry");
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

test("trust.pending shows Trust folder when the folder reads as answered untrusted", async () => {
  // acpmux's gate says pending: a read that says "untrusted" (a stale answer) must not replace the
  // Trust question with Don't trust's Undo, which keeps no replay (#24144 review).
  const cwd = "/Users/you/src/read-untrusted";
  await refusedThenTrusted(async () => ({ cwd, level: "untrusted", decided: true }), cwd, "chat-read-untrusted");
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

test("a stale Trust save cannot make a later chat inherit another chat's refusal", async () => {
  const folderA = "/Users/you/src/save-a";
  const folderB = "/Users/you/src/save-b";
  let resolveSave: (() => void) | undefined;
  const trust: ReturnType<typeof source>["source"] = {
    get: async () => ({ cwd: folderA, level: "trusted", decided: false, auto: "root" }),
    set: async (_cwd, _level) =>
      new Promise<void>((resolve) => {
        resolveSave = resolve;
      }),
  };
  const show = (sessionId: string, cwd: string) =>
    act(async () => root.render(<Pane trust={trust} sessionId={sessionId} cwd={cwd} />));

  await show("chat-save-a", folderA);
  await act(async () => {
    shown!.refused(pending(`${folderA}-real`), () => undefined);
  });
  await act(async () => shown!.trust());

  await show("chat-save-b", folderB);
  await act(async () => {
    shown!.refused(pending(`${folderB}-real`), () => undefined);
  });
  await act(async () => resolveSave!());

  // The old save belonged to A. B's refusal must not leak into a new chat in B's folder.
  await show("chat-save-c", folderB);
  expect(trustButton()).toBeUndefined();
  expect(shown!.blocked).toBeUndefined();
});

test("a completed Trust save reconciles a stale read in another chat in the same folder", async () => {
  const cwd = "/Users/you/src/save-shared";
  let reads = 0;
  let resolveRead: ((value: unknown) => void) | undefined;
  let resolveSave: (() => void) | undefined;
  let resent = 0;
  const trust: ReturnType<typeof source>["source"] = {
    get: () => {
      if (++reads === 1) return Promise.resolve({ cwd, level: "trusted", decided: false, auto: "root" });
      return new Promise((resolve) => {
        resolveRead = resolve;
      });
    },
    set: async (_cwd, _level) =>
      new Promise<void>((resolve) => {
        resolveSave = resolve;
      }),
  };
  const show = (sessionId: string) =>
    act(async () => root.render(<Pane trust={trust} sessionId={sessionId} cwd={cwd} />));
  await show("chat-shared-a");
  await act(async () => {
    shown!.refused(pending(cwd), () => {
      resent += 1;
    });
  });
  await act(async () => shown!.trust());
  await show("chat-shared-b");
  await act(async () => resolveRead!({ cwd, level: "unknown" }));
  expect(shown!.blocked?.reason).toBe("trust.answerFirst");
  await act(async () => resolveSave!());
  expect(shown!.blocked).toBeUndefined();
  expect(trustButton()).toBeUndefined();
  expect(resent).toBe(0);
});

// A failed row's Retry refused by trust.pending (#24144 review): the question shows, and Trust sends
// the row's run again with the gesture the refused retry kept, so no second manual Retry is needed.
test("Trust re-sends a failed row's Retry that acpmux refused with trust.pending", async () => {
  const cwd = "/Users/you/src/retry-row";
  const trust = source(async () => ({ cwd, level: "trusted", decided: false, auto: "root" }));
  await act(async () => root.render(<Pane trust={trust.source} sessionId="chat-retry-row" cwd={cwd} />));
  const calls: { rowIds: readonly string[]; ticket?: string; anchor?: string }[] = [];
  const held: string[] = [];
  let ticket: string | undefined;
  const rowRetry = failedRowTrustRetry({
    retry: async (rowIds, sentTicket, anchor) => {
      calls.push({ rowIds, ticket: sentTicket, anchor });
      // direct.ts `send` marks the refusal with the failed row it kept.
      if (calls.length === 1) throw Object.assign(pending(cwd), { failedRow: "row-2" });
      return "prompt-2";
    },
    runOf: (row) => (row === "row-2" ? ["row-1", "row-2"] : [row]),
    hold: (row) => {
      held.push(row);
      ticket = "gesture-2";
    },
    takeTicket: () => {
      const taken = ticket;
      ticket = undefined;
      return taken;
    },
  });
  let rejected: unknown;
  await act(async () => {
    await rowRetry
      .retry(["row-1", "row-2"], (error, again) => shown!.refused(error, again))
      .catch((error: unknown) => {
        rejected = error;
      });
  });
  // The click still fails as before (the row shows "Still not sent"), and the question shows.
  expect((rejected as { reason?: unknown } | undefined)?.reason).toBe("trust.pending");
  expect(held).toEqual(["row-2"]);
  const button = trustButton();
  const visible = button !== undefined;
  expect(visible).toBe(true);
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  expect(trust.sets).toEqual([[cwd, "trusted"]]);
  expect(calls).toEqual([
    { rowIds: ["row-1", "row-2"], ticket: undefined, anchor: undefined },
    { rowIds: ["row-1", "row-2"], ticket: "gesture-2", anchor: "row-2" },
  ]);
});

test("a refusal that left no failed row keeps no row replay", async () => {
  let routed = 0;
  const rowRetry = failedRowTrustRetry({
    retry: async () => {
      throw pending("/Users/you/src/no-row");
    },
    runOf: (row) => [row],
    hold: () => {
      throw new Error("nothing to hold");
    },
    takeTicket: () => undefined,
  });
  const error = await rowRetry
    .retry(["row-1"], () => {
      routed += 1;
      return true;
    })
    .catch((caught: unknown) => caught);
  expect((error as { reason?: unknown }).reason).toBe("trust.pending");
  expect(routed).toBe(0);
});

test("the pane's failed-row Retry goes through the trust replay", () => {
  const app = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/App.tsx"), "utf8");
  const action = app.match(/"chat\.retryPrompt": \(\{ rowId, rowIds \}\) => \{([\s\S]*?)\n {10}\},/)?.[1] ?? "";
  expect(action).toContain("rowRetry.retry(failedRowIds(rowId, rowIds)");
  expect(action).not.toContain("client.retryPrompts(");
});

test("Trust does not resend a refused prompt after the pane unmounts", async () => {
  const chatCwd = "/Users/you/src/disposed";
  let resolveSave: (() => void) | undefined;
  let resent = 0;
  const trust = {
    get: async () => ({ cwd: chatCwd, level: "trusted", decided: false, auto: "root" }),
    set: () =>
      new Promise<void>((resolve) => {
        resolveSave = resolve;
      }),
  };

  await act(async () => root.render(<Pane trust={trust} sessionId="chat-disposed" cwd={chatCwd} />));
  await act(async () => {
    shown!.refused(pending("/Users/you/src/disposed-real"), () => {
      resent += 1;
    });
  });
  await act(async () => shown!.trust());
  await act(async () => root.unmount());
  await act(async () => resolveSave!());

  expect(resent).toBe(0);
});
