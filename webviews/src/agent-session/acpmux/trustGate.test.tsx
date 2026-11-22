import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

// While the chat's folder has no trust answer, no prompt goes: the composer keeps what was typed,
// its Send is off, and the note says why. acpmux refuses the prompt too (`trust_gate.rs`).
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const React = await import("react");
const { act, createElement } = React;
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { TrustAsk } = await import("./TrustAsk");
const { useFolderTrustAsk } = await import("./useFolderTrustAsk");
const { promptField: fieldIn, typeInto } = await import("./promptFieldTesting");
type TrustLevel = import("./folderTrust").TrustLevel;

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 10)));
const settled = async () => {
  await settle();
  await settle();
};

const snapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};

const field = () => fieldIn(doc);
const send = () => doc.querySelector<HTMLButtonElement>(".acpmux-send");
const note = () => doc.querySelector(".acpmux-composer-trust-note")?.textContent ?? null;
const enter = () =>
  act(async () => {
    field().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
const press = async (label: string) => {
  await act(async () =>
    [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask-action")]
      .find((button) => button.textContent === label)!
      .click(),
  );
  await settled();
};

/// The trust question and the composer, wired as App wires them.
function Pane({
  replies,
  chat,
  sent,
  remote = false,
}: {
  replies: Map<string, Record<string, unknown>>;
  chat: { sessionId?: string; cwd?: string; family?: string; prompts: number };
  sent: string[];
  remote?: boolean;
}) {
  const source = React.useMemo(
    () => ({
      get: async (cwd: string) => ({ cwd, level: "unknown", ...replies.get(cwd) }),
      set: async (cwd: string, level: TrustLevel) => {
        if (level === "unknown") replies.delete(cwd);
        else replies.set(cwd, { level, decided: true });
        return { cwd, level };
      },
    }),
    [replies],
  );
  const trust = useFolderTrustAsk(source, chat, !remote);
  return createElement(
    React.Fragment,
    null,
    trust.ask
      ? createElement(TrustAsk, {
          ask: trust.ask,
          agent: "Claude Code",
          onTrust: trust.trust,
          onDistrust: trust.distrust,
          onUndo: trust.undo,
        })
      : null,
    createElement(Composer, {
      snapshot,
      chips: () => null,
      blocked: trust.blocked,
      onSend: (text: string) => {
        sent.push(text);
      },
      onStop: () => {},
    }),
  );
}
const render = async (props: Parameters<typeof Pane>[0]) => {
  await act(async () => root.render(createElement(Pane, props)));
  await settled();
};

test("a new chat asks before its first prompt, and Enter sends nothing until Trust", async () => {
  const sent: string[] = [];
  const replies = new Map<string, Record<string, unknown>>();
  await render({ replies, chat: { cwd: "/Users/me", family: "claude", prompts: 0 }, sent });
  expect(doc.querySelector(".acpmux-trust-ask")!.textContent).toContain("can edit and run code in /Users/me");

  await act(async () => typeInto(field(), "Reply with only the word pong."));
  await enter();
  expect(sent).toEqual([]);
  // The typed prompt stays in the composer.
  expect(field().value).toBe("Reply with only the word pong.");
  expect(send()!.disabled).toBe(true);
  expect(send()!.title).toBe("Answer the trust question first");
  expect(note()).toBe("Answer the trust question first");

  await press("Trust");
  expect(send()!.disabled).toBe(false);
  expect(note()).toBeNull();
  await enter();
  expect(sent).toEqual(["Reply with only the word pong."]);
});

test("a remote browser sees where to answer trust and no answer buttons", async () => {
  const sent: string[] = [];
  const replies = new Map<string, Record<string, unknown>>();
  await render({ replies, chat: { cwd: "/Users/me", family: "claude", prompts: 0 }, sent, remote: true });
  expect(doc.querySelector(".acpmux-trust-ask")!.textContent).toBe(
    "Answer the trust question in the cmux app on this Mac",
  );
  expect(doc.querySelectorAll(".acpmux-trust-ask-action")).toHaveLength(0);
  expect(send()!.disabled).toBe(true);
});

test("Don't trust keeps prompts from the agent and says why; Undo asks again", async () => {
  const sent: string[] = [];
  const replies = new Map<string, Record<string, unknown>>();
  await render({ replies, chat: { sessionId: "s", cwd: "/work/app", family: "claude", prompts: 0 }, sent });
  await press("Don't trust");
  await act(async () => typeInto(field(), "hello"));
  await enter();
  expect(sent).toEqual([]);
  expect(field().value).toBe("hello");
  expect(send()!.disabled).toBe(true);
  expect(note()).toBe("You chose Don't trust, so the agent runs no prompts in this folder. Press Undo to change it.");
  await press("Undo");
  expect(note()).toBe("Answer the trust question first");
});

test("a folder acpmux reads as untrusted shows the answer with Undo, and Send stays off", async () => {
  const sent: string[] = [];
  const replies = new Map<string, Record<string, unknown>>([["/work/app", { level: "untrusted", decided: true }]]);
  await render({ replies, chat: { sessionId: "s", cwd: "/work/app", family: "claude", prompts: 3 }, sent });
  expect(doc.querySelector(".acpmux-trust-ask")!.textContent).toBe("Won't trust appUndo");
  expect(send()!.disabled).toBe(true);
});

test("the session's own agent answers when acpmux has no decision", async () => {
  const sent: string[] = [];
  // Claude Code accepted its dialog for the folder; Codex knows nothing: the projection is unknown.
  const replies = new Map<string, Record<string, unknown>>([
    ["/work/app", { level: "unknown", decided: false, harnesses: { claude: "trusted", codex: "unknown" } }],
  ]);
  await render({ replies, chat: { sessionId: "s", cwd: "/work/app", family: "claude", prompts: 0 }, sent });
  expect(doc.querySelector(".acpmux-trust-ask")).toBeNull();
  expect(send()!.disabled).toBe(false);
  await render({ replies, chat: { sessionId: "t", cwd: "/work/app", family: "codex", prompts: 0 }, sent });
  expect(doc.querySelector(".acpmux-trust-ask")).not.toBeNull();
  expect(send()!.disabled).toBe(true);
});

/// Enter does not clear the composer until the host takes the prompt: a refusal keeps it, and
/// what was typed meanwhile stays after the host takes it.
test("Enter keeps the prompt until the host takes it, and a refusal keeps it", async () => {
  let settleSend: { take(): void; refuse(): void } | undefined;
  const sent: string[] = [];
  function Held() {
    return createElement(Composer, {
      snapshot,
      chips: () => null,
      onSend: (text: string) => {
        sent.push(text);
        return new Promise<void>((take, refuse) => {
          settleSend = { take: () => take(), refuse: () => refuse(new Error("refused")) };
        });
      },
      onStop: () => {},
    });
  }
  await act(async () => root.render(createElement(Held)));
  await settled();
  await act(async () => typeInto(field(), "first"));
  await enter();
  expect(sent).toEqual(["first"]);
  expect(field().value).toBe("first");
  // A second Enter while the host decides sends no copy.
  await enter();
  expect(sent).toEqual(["first"]);
  await act(async () => settleSend!.refuse());
  await settled();
  expect(field().value).toBe("first");

  await enter();
  expect(sent).toEqual(["first", "first"]);
  await act(async () => settleSend!.take());
  await settled();
  expect(field().value).toBe("");
});

/// The pane wired as App wires a refused first send: the composer holds the prompt, acpmux's
/// refusal names the folder (a new chat's folder the host filled in, unknown to the page).
function RefusedPane({
  replies,
  sent,
  refusal,
  accepts,
}: {
  replies: Map<string, Record<string, unknown>>;
  sent: string[];
  refusal: { reason: string; cwd: string };
  /// Each send the host takes waits here until the test accepts it.
  accepts?: (() => void)[];
}) {
  const composer = React.useRef<import("./Composer").ComposerHandle | null>(null);
  const source = React.useMemo(
    () => ({
      get: async (cwd: string) => ({ cwd, level: "unknown", ...replies.get(cwd) }),
      set: async (cwd: string, level: TrustLevel) => {
        replies.set(cwd, { level, decided: true });
        return { cwd, level };
      },
    }),
    [replies],
  );
  const trust = useFolderTrustAsk(source, { prompts: 0 });
  return createElement(
    React.Fragment,
    null,
    trust.ask
      ? createElement(TrustAsk, {
          ask: trust.ask,
          agent: "Claude Code",
          onTrust: trust.trust,
          onDistrust: trust.distrust,
          onUndo: trust.undo,
        })
      : null,
    createElement(Composer, {
      snapshot,
      chips: () => null,
      blocked: trust.blocked,
      handle: composer,
      onSend: (text: string) => {
        sent.push(text);
        const level = replies.get(refusal.cwd)?.level;
        if (level === "trusted")
          return accepts ? new Promise<void>((resolve) => accepts.push(() => resolve())) : Promise.resolve();
        const error = Object.assign(new Error(refusal.reason), refusal);
        trust.refused(error, () => composer.current?.send());
        return Promise.reject(error);
      },
      onStop: () => {},
    }),
  );
}

test("a trust.pending refusal on the first send keeps the prompt, asks, and Trust sends it", async () => {
  const sent: string[] = [];
  const replies = new Map<string, Record<string, unknown>>();
  const refusal = { reason: "trust.pending", cwd: "/agent-home/w1" };
  await act(async () => root.render(createElement(RefusedPane, { replies, sent, refusal })));
  await settled();
  // The page does not know the folder: no question yet.
  expect(doc.querySelector(".acpmux-trust-ask")).toBeNull();
  await act(async () => typeInto(field(), "hello agent"));
  await enter();
  await settled();
  expect(sent).toEqual(["hello agent"]);
  // The prompt is still in the composer, and the question names acpmux's folder.
  expect(field().value).toBe("hello agent");
  expect(doc.querySelector(".acpmux-trust-ask")!.textContent).toContain("can edit and run code in w1");
  expect(note()).toBe("Answer the trust question first");

  // One gesture: Trust sends the prompt the composer held.
  await press("Trust");
  await settled();
  expect(sent).toEqual(["hello agent", "hello agent"]);
  expect(field().value).toBe("");
});

test("Don't trust after a refused first send keeps the prompt with the reason", async () => {
  const sent: string[] = [];
  const replies = new Map<string, Record<string, unknown>>();
  const refusal = { reason: "trust.pending", cwd: "/agent-home/w2" };
  await act(async () => root.render(createElement(RefusedPane, { replies, sent, refusal })));
  await settled();
  await act(async () => typeInto(field(), "keep me"));
  await enter();
  await settled();
  await press("Don't trust");
  await settled();
  expect(sent).toEqual(["keep me"]);
  expect(field().value).toBe("keep me");
  expect(note()).toBe("You chose Don't trust, so the agent runs no prompts in this folder. Press Undo to change it.");
});

test("send, trust.pending, Trust: the prompt is delivered exactly once, cleared only after accept", async () => {
  const sent: string[] = [];
  const accepts: (() => void)[] = [];
  const replies = new Map<string, Record<string, unknown>>();
  const refusal = { reason: "trust.pending", cwd: "/agent-home/w3" };
  await act(async () => root.render(createElement(RefusedPane, { replies, sent, refusal, accepts })));
  await settled();
  await act(async () => typeInto(field(), "once only"));
  await enter();
  await settled();
  await press("Trust");
  await settled();
  // Sent again once after Trust; the host has not taken it yet, so the composer keeps it.
  expect(sent).toEqual(["once only", "once only"]);
  expect(accepts).toHaveLength(1);
  expect(field().value).toBe("once only");
  // Enter while the host decides sends no copy.
  await enter();
  expect(sent).toEqual(["once only", "once only"]);
  await act(async () => accepts[0]!());
  await settled();
  expect(field().value).toBe("");
  expect(sent).toEqual(["once only", "once only"]);
});
