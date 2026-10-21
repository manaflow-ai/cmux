// l10n-allow-file: test fixture asks, chat names and commands, not shipped UI.
// Needs you (Leo 2026-10-20): one list of every open ask from every agent chat and the Chief, so no
// agent has to restate "still waiting on you". These tests hold the list to what acpmux reports:
// each kind of ask reads as its kind with its one-click answers, a chat waiting with no readable ask
// is never missing, held agent pair messages offer Resume, an answer goes out the way the ask's card
// sends it (to the ask's own chat), links name an ask, the Needs your input pill visits this chat's
// ask first and cycles the others, and the panel draws, answers and hides what was answered.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxPermission, AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { AgentQuestion } from "../src/agent-session/acpmux/question/model";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { needsYouItems, type NeedsYouItem, type WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";
import { needsYouLink, needsYouTarget, onOpenNeedsYou, openNeedsYou } from "../src/agent-session/acpmux/needsYou/links";
import { nextAsk, NeedsYouPill } from "../src/agent-session/acpmux/needsYou/JumpPill";
import { answerParams } from "../src/agent-session/acpmux/needsYou/useNeedsYou";
import {
  NeedsYouPanel,
  needsYouMode,
  sideQuestionPrompt,
  type NeedsYouActions,
} from "../src/agent-session/acpmux/needsYou/NeedsYou";

const options: AcpmuxPermission["options"] = [
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "always", name: "Always allow", kind: "allow_always", allow: true },
  { id: "deny", name: "Deny", kind: "reject_once", allow: false },
];
const permission = (fields: Partial<AcpmuxPermission>): AcpmuxPermission => ({
  permissionId: "p1",
  pending: true,
  options,
  ...fields,
});
const question = (fields: Partial<AgentQuestion> = {}): AgentQuestion => ({
  id: "q-perm",
  source: { harness: "claude", session: "s-q", permission: "q-perm", answerOption: "allow_once" },
  items: [
    {
      id: "q0",
      header: "Auth",
      prompt: "Which login should the app use?",
      options: [
        { id: "OAuth", label: "OAuth" },
        { id: "Passkeys", label: "Passkeys" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
  ...fields,
});
const session = (sessionId: string, fields: Partial<AcpmuxSessionEntry> = {}): AcpmuxSessionEntry => ({
  sessionId,
  name: sessionId,
  harness: "claude",
  ...fields,
});
const ask = (sessionId: string, p: AcpmuxPermission, at: number): WatchedAsk => ({ sessionId, permission: p, at });

test("an approval reads its title, offers allow once and deny once, and keys on the Feed's id", () => {
  const items = needsYouItems({
    sessions: [session("s1", { displayTitle: "Fix login" })],
    asks: [ask("s1", permission({ title: "Run npm test", command: "npm test", turnId: "t9" }), 10)],
  });
  expect(items).toHaveLength(1);
  const [item] = items as [NeedsYouItem];
  expect(item.id).toBe("acpmux:p1");
  expect(item.kind).toBe("approval");
  expect(item.ask).toBe("Run npm test");
  expect(item.detail).toBe("npm test");
  expect(item.command).toBe(true);
  expect(item.who.name).toBe("Fix login");
  expect(item.turnId).toBe("t9");
  // Always allow is the card's to give, where its scope is spelled out.
  expect(item.answers.map((answer) => answer.id)).toEqual(["allow", "deny"]);
});

test("a question is a decision with its choices; a Chief question is the Chief's; verify asks read as verify", () => {
  const items = needsYouItems({
    sessions: [session("s-q"), session("s-v"), session("s-c", { harness: "chief", name: "Chief" })],
    asks: [
      ask("s-q", permission({ permissionId: "q-perm", question: question() }), 3),
      ask("s-v", permission({ permissionId: "v-perm", title: "Verify the sidebar dot in dark mode" }), 2),
      ask("s-c", permission({ permissionId: "c-perm", title: "Merge #22410?" }), 1),
    ],
  });
  expect(items.map((item) => item.kind)).toEqual(["decision", "verify", "approval"]);
  expect(items[0]!.ask).toBe("Which login should the app use?");
  expect(items[0]!.answers.map((answer) => answer.label)).toEqual(["OAuth", "Passkeys"]);
  expect(items[2]!.who.chief).toBe(true);
  expect(items[0]!.who.chief).toBe(false);
});

test("a question with several items or many choices gets no one-click answers", () => {
  const big = question();
  big.items[0]!.options = ["a", "b", "c", "d", "e"].map((id) => ({ id, label: id }));
  const multi = question();
  multi.items[0]!.multiSelect = true;
  const items = needsYouItems({
    sessions: [session("s1")],
    asks: [
      ask("s1", permission({ permissionId: "big", question: big }), 2),
      ask("s1", permission({ permissionId: "multi", question: multi }), 1),
    ],
  });
  expect(items.map((item) => item.answers.length)).toEqual([0, 0]);
});

test("a chat waiting with no readable ask still shows, once; an archived chat never does", () => {
  const items = needsYouItems({
    sessions: [
      session("remote", { indicator: "input", updatedAt: 5, preview: "Pick a branch" }),
      session("counted", { pendingPermissions: 2 }),
      session("asked", { pendingPermissions: 1 }),
      session("gone", { indicator: "input", archived: true }),
      session("idle"),
    ],
    asks: [ask("asked", permission({}), 9), ask("gone", permission({ permissionId: "p-gone" }), 8)],
  });
  expect(items.map((item) => item.id)).toEqual(["acpmux:p1", "chat:remote", "chat:counted"]);
  expect(items[1]!.kind).toBe("input");
  expect(items[1]!.ask).toBe("Pick a branch");
});

test("the open chat's held agent pair messages are one item with Resume; a resumed pair is not", () => {
  const pair = (peer: string, resumed: boolean) =>
    ({
      kind: "agentPair",
      agentPair: {
        peer,
        peerName: `Agent ${peer}`,
        reason: "alternating",
        count: 10,
        held: [{ promptId: `${peer}-1`, text: "LGTM?" }],
        released: 0,
        dropped: 0,
        ...(resumed ? { resumed: true } : {}),
      },
    }) as unknown as AcpmuxRow;
  const items = needsYouItems({
    sessions: [session("s1")],
    asks: [],
    open: { sessionId: "s1", rows: [pair("a", false), pair("b", false), pair("b", true)] },
  });
  expect(items).toHaveLength(1);
  expect(items[0]).toMatchObject({ id: "held:s1:a", kind: "held", peer: "a", held: 1, ask: "Agent a" });
  expect(answerParams(items[0]!, items[0]!.answers[0]!)).toEqual({
    method: "chat.agentPair.resume",
    params: { peer: "a" },
  });
});

test("a subagent's ask names the chat that started it", () => {
  const [item] = needsYouItems({
    sessions: [session("parent", { displayTitle: "Chief plan" }), session("child", { spawnedBy: "parent" })],
    asks: [ask("child", permission({}), 1)],
  });
  expect(item!.who.via).toBe("Chief plan");
});

test("an answer goes to the ask's own chat: a permission by option, a question in its harness's shape", () => {
  const [approval, decision] = [
    needsYouItems({ sessions: [session("s1")], asks: [ask("s1", permission({}), 1)] })[0]!,
    needsYouItems({
      sessions: [session("s-q")],
      asks: [ask("s-q", permission({ permissionId: "q-perm", question: question() }), 1)],
    })[0]!,
  ];
  expect(answerParams(approval, approval.answers[1]!)).toEqual({
    method: "chat.permission",
    params: { sessionId: "s1", permissionId: "p1", optionId: "deny" },
  });
  expect(answerParams(decision, decision.answers[1]!)).toEqual({
    method: "chat.permission",
    params: {
      sessionId: "s-q",
      permissionId: "q-perm",
      optionId: "allow_once",
      answers: { "Which login should the app use?": "Passkeys" },
    },
  });
  // A waiting chat with no ask read is answered at its source.
  const waiting = needsYouItems({ sessions: [session("r", { indicator: "input" })], asks: [] })[0]!;
  expect(answerParams(waiting, { id: "x", label: "x", tone: "choice" })).toBeUndefined();
});

test("a needs-you link names its ask in any build's scheme and nothing else", () => {
  expect(needsYouTarget("cmux://needs-you/0f4e-11")).toBe("acpmux:0f4e-11");
  expect(needsYouTarget("cmux-dev-tag://needs-you/abc")).toBe("acpmux:abc");
  expect(needsYouTarget("https://needs-you/abc")).toBeUndefined();
  expect(needsYouTarget("cmux://needs-you/a/b")).toBeUndefined();
  expect(needsYouTarget("cmux://needs-you/a%20b")).toBeUndefined();
  expect(needsYouLink("abc")).toBe("cmux://needs-you/abc");
  expect(needsYouLink("../x/y")).toBeUndefined();
  const opened: (string | undefined)[] = [];
  expect(openNeedsYou("acpmux:abc")).toBe(false);
  const off = onOpenNeedsYou((id) => opened.push(id));
  expect(openNeedsYou("acpmux:abc")).toBe(true);
  off();
  expect(opened).toEqual(["acpmux:abc"]);
});

test("the pill goes to this chat's ask first, then cycles the asks open elsewhere", () => {
  const item = (id: string, sessionId: string) =>
    ({ id, sessionId, kind: "approval", ask: id, who: { name: sessionId, chief: false }, answers: [] }) as NeedsYouItem;
  const items = [item("x1", "other"), item("h1", "here"), item("y1", "third")];
  // Behind: the press jumped to the latest message, where this chat's ask card waits.
  expect(nextAsk(items, "here", true, undefined)).toBeUndefined();
  // At the latest message already: on to the others, in turn, and around again.
  expect(nextAsk(items, "here", false, undefined)?.id).toBe("x1");
  expect(nextAsk(items, "here", false, "x1")?.id).toBe("y1");
  expect(nextAsk(items, "here", false, "y1")?.id).toBe("x1");
  // No ask here: even a press from behind moves on to the others.
  expect(nextAsk([item("x1", "other")], "here", true, undefined)?.id).toBe("x1");
  expect(nextAsk([item("h1", "here")], "here", false, undefined)).toBeUndefined();
});

test("the pill reads Needs your input, and how many when several are open", () => {
  const one = renderToStaticMarkup(<NeedsYouPill count={1} shown lift={0} onJump={() => undefined} />);
  expect(one).toContain(translate("needsYou.pill"));
  expect(one).toContain("acpmux-needs-you-dot");
  expect(one).toContain("acpmux-jump-latest");
  const three = renderToStaticMarkup(<NeedsYouPill count={3} shown lift={0} onJump={() => undefined} />);
  expect(three).toContain(translate("needsYou.pillCount", { n: 3 }));
});

test("the Debug Settings attributes pick the list's mode", () => {
  const root = (value?: string) => ({ dataset: value ? { needsYou: value } : {} }) as { dataset: DOMStringMap };
  expect(needsYouMode(root())).toBe("pinned");
  expect(needsYouMode(root("compact"))).toBe("compact");
  expect(needsYouMode(root("off"))).toBe("off");
  expect(needsYouMode(root("bogus"))).toBe("pinned");
});

test("the side question carries the ask, its choices and earlier answers", () => {
  const [item] = needsYouItems({
    sessions: [session("s-q")],
    asks: [ask("s-q", permission({ permissionId: "q-perm", question: question() }), 1)],
  });
  const prompt = sideQuestionPrompt(item!, "Which is safer?", [
    { question: "What is this?", answer: "A login choice." },
  ]);
  expect(prompt).toContain("Which login should the app use?");
  expect(prompt).toContain("Choices: OAuth / Passkeys");
  expect(prompt).toContain("You said: A login choice.");
  expect(prompt).toContain("My question: Which is safer?");
});

// ---------- The panel ----------

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  return dom.window.document.getElementById("root")!;
}

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

const click = (element: Element) => element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
const buttonNamed = (host: HTMLElement, name: string) =>
  [...host.querySelectorAll("button")].find((button) => button.textContent === name);

test("the panel lists each ask with who asked, answers it, and hides it once sent", async () => {
  const host = installDom();
  const items = needsYouItems({
    sessions: [session("s1", { displayTitle: "Fix login" }), session("c", { harness: "chief", name: "Chief" })],
    asks: [
      ask("s1", permission({ title: "Run npm test" }), Date.now()),
      ask("c", permission({ permissionId: "p2", title: "Merge?" }), 1),
    ],
  });
  const answered: string[] = [];
  const went: string[] = [];
  const actions: NeedsYouActions = {
    answer: async (item, choice) => void answered.push(`${item.id}:${choice.id}`),
    goTo: (item) => void went.push(item.id),
    ask: async () => "",
  };
  root = createRoot(host);
  await act(async () => root!.render(<NeedsYouPanel items={items} actions={actions} />));
  expect(host.querySelectorAll(".acpmux-needs-you-item")).toHaveLength(2);
  expect(host.textContent).toContain("Fix login");
  expect(host.textContent).toContain(translate("needsYou.chief"));
  expect(host.querySelector(".acpmux-needs-you-total")!.textContent).toBe("2");
  await act(async () => click(host.querySelector(".acpmux-needs-you-go")!));
  expect(went).toEqual(["acpmux:p1"]);
  await act(async () => click(buttonNamed(host, "Allow")!));
  expect(answered).toEqual(["acpmux:p1:allow"]);
  expect(host.querySelectorAll(".acpmux-needs-you-item")).toHaveLength(1);
});

test("a refused answer stays in the list and says so; the empty list says nothing waits", async () => {
  const host = installDom();
  const items = needsYouItems({ sessions: [session("s1")], asks: [ask("s1", permission({ title: "Run it" }), 1)] });
  const actions: NeedsYouActions = {
    answer: async () => Promise.reject(new Error("gone")),
    goTo: () => undefined,
    ask: async () => "",
  };
  root = createRoot(host);
  await act(async () => root!.render(<NeedsYouPanel items={items} actions={actions} />));
  await act(async () => click(buttonNamed(host, "Deny")!));
  expect(host.querySelectorAll(".acpmux-needs-you-item")).toHaveLength(1);
  expect(host.textContent).toContain(translate("needsYou.answerFailed"));
  await act(async () => root!.render(<NeedsYouPanel items={[]} actions={actions} />));
  expect(host.textContent).toContain(translate("needsYou.empty"));
});

test("compact mode lists asks without answers", () => {
  const items = needsYouItems({ sessions: [session("s1")], asks: [ask("s1", permission({ title: "Run it" }), 1)] });
  const html = renderToStaticMarkup(
    <NeedsYouPanel
      items={items}
      mode="compact"
      actions={{ answer: async () => undefined, goTo: () => undefined, ask: async () => "" }}
    />,
  );
  expect(html).toContain("Run it");
  expect(html).not.toContain("acpmux-needs-you-answer");
});
