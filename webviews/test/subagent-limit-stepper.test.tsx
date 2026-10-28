// l10n-allow-file: test fixture chat titles.
// The Inspector's Subagents card names how many of the chats this chat's agent started run a turn
// at once (acpmux `subsessionLimits.maxRunning`): "Running 2 / 16 max", "1 queued" while some wait
// for a slot, and − / + that set the chat's own limit one lower or higher, 1 to 1000, through
// `_acpmux/subsession/limits` (Leo, 2026-10-21: "increase or decrease subagent amounts ad hoc").
// The number moves at once and acpmux's answer then holds; an acpmux without the limit draws
// nothing. Subagents shows for a chat that has had subagents or sub-sessions, or whose limit someone
// set (any source but acpmux's default), even before any chat starts; a chat that never used them,
// at the default, shows no Subagents card.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { SubagentLimitStepper } from "../src/agent-session/acpmux/inspector/SubagentLimitStepper";
import { resetInspectorState } from "../src/agent-session/acpmux/inspector/inspectorState";
import type { SubsessionLimits } from "../src/agent-session/acpmux/model";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";
import { startedSessions, type StartedSession } from "../src/agent-session/acpmux/started/startedSessions";
import { slotCounts, subsessionLimits } from "../src/agent-session/acpmux/subsessionLimits";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/", pretendToBeVisual: true });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetInspectorState();
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetInspectorState();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode) {
  await act(async () => {
    root ??= createRoot(host);
    root.render(node);
  });
}

const button = (name: RegExp) =>
  [...host.querySelectorAll("button")].find((each) => name.test(each.getAttribute("aria-label") ?? ""));

async function click(element: Element | undefined) {
  expect(element).toBeDefined();
  await act(async () => {
    element!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
}

const line = () => host.querySelector(".acpmux-subagent-limit__text")?.textContent ?? "";

const child = (sessionId: string, state: StartedSession["state"], extra: Partial<StartedSession> = {}) => ({
  sessionId,
  title: sessionId,
  state,
  ...extra,
});

test("acpmux's limits are read only with maxRunning, held in its range", () => {
  expect(subsessionLimits(undefined)).toBeUndefined();
  // An older acpmux: width and depth only.
  expect(subsessionLimits({ maxChildren: 8, maxDepth: 2 })).toBeUndefined();
  expect(subsessionLimits({ maxRunning: 0 })).toBeUndefined();
  expect(subsessionLimits({ maxRunning: 16, maxRunningSource: "default", running: 2, queued: 1 })).toEqual({
    maxRunning: 16,
    maxRunningSource: "default",
    running: 2,
    queued: 1,
  });
  expect(subsessionLimits({ maxRunning: 5000, maxRunningSource: "nonsense" })).toEqual({ maxRunning: 1000 });
});

test("the counts are the started chats' live states, a chat waiting for a slot queued", () => {
  const limits: SubsessionLimits = { maxRunning: 2, running: 9, queued: 9 };
  // No chat listed yet: acpmux's own counts.
  expect(slotCounts(limits, [])).toEqual({ running: 9, queued: 9 });
  expect(
    slotCounts(limits, [
      child("a", "running"),
      child("b", "waiting"),
      child("c", "idle", { waitsForSlot: true }),
      child("d", "idle"),
      child("e", "failed"),
    ]),
  ).toEqual({ running: 2, queued: 1 });
  // The session list's `waitsForSlot` reaches the started chats.
  const entries = [
    sessionEntry({ sessionId: "kid", spawnedBy: "parent", waitsForSlot: true }),
    sessionEntry({ sessionId: "other", spawnedBy: "parent" }),
  ];
  expect(startedSessions(entries, "parent").map((each) => each.waitsForSlot)).toEqual([true, undefined]);
});

test("it reads Running N / M max with the queued count, and draws nothing without the limit", async () => {
  await render(<SubagentLimitStepper limits={undefined} />);
  expect(host.querySelector(".acpmux-subagent-limit")).toBeNull();
  await render(
    <SubagentLimitStepper
      limits={{ maxRunning: 16, maxRunningSource: "default" }}
      sessions={[child("a", "running"), child("b", "idle", { waitsForSlot: true })]}
      onSet={async () => undefined}
    />,
  );
  expect(line()).toBe("Running 1 / 16 max · 1 queued");
  expect(button(/Lower the running limit to 15/)).toBeDefined();
  expect(button(/Raise the running limit to 17/)).toBeDefined();
  // Not the chat's own limit: nothing to reset.
  expect(button(/inherited/)).toBeUndefined();
  // Without a way to set it, it only reads.
  await render(<SubagentLimitStepper limits={{ maxRunning: 16 }} />);
  expect(line()).toBe("Running 0 / 16 max");
  expect(host.querySelectorAll("button").length).toBe(0);
});

test("− and + send max ∓ 1 for the chat, move at once and clamp to 1..1000", async () => {
  const sent: (number | null)[] = [];
  let answer: (() => void) | undefined;
  const onSet = (value: number | null) => {
    sent.push(value);
    return new Promise<void>((resolve) => (answer = resolve));
  };
  await render(<SubagentLimitStepper limits={{ maxRunning: 16 }} onSet={onSet} />);
  await click(button(/Raise/));
  expect(sent).toEqual([17]);
  // Optimistic: the number moved before acpmux answered.
  expect(line()).toBe("Running 0 / 17 max");
  await click(button(/Raise/));
  expect(sent).toEqual([17, 18]);
  // acpmux's answer wins: its limit replaces the asked one.
  await render(<SubagentLimitStepper limits={{ maxRunning: 18, maxRunningSource: "session" }} onSet={onSet} />);
  await act(async () => answer?.());
  expect(line()).toBe("Running 0 / 18 max");
  await click(button(/Lower/));
  expect(sent.at(-1)).toBe(17);
  // Reset drops the chat's own limit.
  await click(button(/inherited/));
  expect(sent.at(-1)).toBeNull();

  await render(<SubagentLimitStepper limits={{ maxRunning: 1 }} onSet={onSet} />);
  expect(button(/Lower/)?.hasAttribute("disabled")).toBe(true);
  await render(<SubagentLimitStepper limits={{ maxRunning: 1000 }} onSet={onSet} />);
  expect(button(/Raise/)?.hasAttribute("disabled")).toBe(true);
});

test("an earlier click's reply keeps the newer click's value, so the next + builds on it", async () => {
  const sent: (number | null)[] = [];
  const answers: (() => void)[] = [];
  const onSet = (value: number | null) => {
    sent.push(value);
    return new Promise<void>((resolve) => answers.push(resolve));
  };
  await render(<SubagentLimitStepper limits={{ maxRunning: 16 }} onSet={onSet} />);
  await click(button(/Raise/));
  await click(button(/Raise/));
  expect(sent).toEqual([17, 18]);
  // The first reply lands: acpmux now says 17, but 18 is still asked.
  await render(<SubagentLimitStepper limits={{ maxRunning: 17, maxRunningSource: "session" }} onSet={onSet} />);
  await act(async () => answers[0]?.());
  expect(line()).toBe("Running 0 / 18 max");
  await click(button(/Raise/));
  expect(sent).toEqual([17, 18, 19]);
  expect(line()).toBe("Running 0 / 19 max");
  // A limit that is none of the asked ones (another client) replaces the ask.
  await render(<SubagentLimitStepper limits={{ maxRunning: 40, maxRunningSource: "session" }} onSet={onSet} />);
  expect(line()).toBe("Running 0 / 40 max");
});

test("a refused change goes back to acpmux's limit and says so", async () => {
  await render(
    <SubagentLimitStepper
      chatId="chat-1"
      limits={{ maxRunning: 4 }}
      onSet={() => Promise.reject(new Error("person_required"))}
    />,
  );
  await click(button(/Raise/));
  expect(line()).toBe("Running 0 / 4 max");
  expect(host.querySelector(".acpmux-subagent-limit__refused")?.textContent).toBe("Couldn't change the limit");
  // Another chat's line says nothing of it.
  await render(<SubagentLimitStepper chatId="chat-2" limits={{ maxRunning: 4 }} onSet={async () => undefined} />);
  expect(host.querySelector(".acpmux-subagent-limit__refused")?.textContent).toBe("");
});

test("a value asked for one chat never shows on another", async () => {
  const onSet = () => new Promise<void>(() => undefined);
  await render(<SubagentLimitStepper chatId="chat-1" limits={{ maxRunning: 16 }} onSet={onSet} />);
  await click(button(/Raise/));
  expect(line()).toBe("Running 0 / 17 max");
  // The pane switched chats while acpmux had not answered: the other chat's own limit shows.
  await render(<SubagentLimitStepper chatId="chat-2" limits={{ maxRunning: 16 }} onSet={onSet} />);
  expect(line()).toBe("Running 0 / 16 max");
});

test("Subagents shows a set limit before the agent starts a chat, and sets it for that chat", async () => {
  const sent: [string, number | null][] = [];
  // Never used, at acpmux's default: no Subagents card.
  await render(
    <ChatInspector
      summary={{ sessionId: "chat-1", subsessionLimits: { maxRunning: 16, maxRunningSource: "default" } }}
      onSetRunningLimit={async (sessionId, value) => void sent.push([sessionId, value])}
    />,
  );
  expect(host.querySelector(".acpmux-subagent-limit")).toBeNull();
  // At the default but with a chat it started: the card and its limit show.
  await render(
    <ChatInspector
      summary={{ sessionId: "chat-1", subsessionLimits: { maxRunning: 16, maxRunningSource: "default" } }}
      sessions={[child("kid", "running")]}
      onSetRunningLimit={async (sessionId, value) => void sent.push([sessionId, value])}
    />,
  );
  expect(line()).toBe("Running 1 / 16 max");
  // No chats yet, but the settings set the limit: the card shows only the limit.
  await render(
    <ChatInspector
      summary={{ sessionId: "chat-1", subsessionLimits: { maxRunning: 16, maxRunningSource: "settings" } }}
      onSetRunningLimit={async (sessionId, value) => void sent.push([sessionId, value])}
    />,
  );
  expect(line()).toBe("Running 0 / 16 max");
  // No avatar row with nothing in it.
  expect(host.querySelector(".acpmux-chat-inspector-avatars")).toBeNull();
  await click(button(/Lower/));
  expect(sent).toEqual([["chat-1", 15]]);
  // A chat on another machine: its acpmux takes the limit only from its own person, so it only reads.
  await render(
    <ChatInspector
      summary={{
        sessionId: "chat-1",
        peer: "build-01",
        subsessionLimits: { maxRunning: 16, maxRunningSource: "workspace" },
      }}
      onSetRunningLimit={async (sessionId, value) => void sent.push([sessionId, value])}
    />,
  );
  expect(line()).toBe("Running 0 / 16 max");
  expect(host.querySelectorAll(".acpmux-subagent-limit button").length).toBe(0);
  // An acpmux without the limit and no chats: no Subagents at all.
  await render(<ChatInspector summary={{ sessionId: "chat-1" }} />);
  expect(host.querySelector(".acpmux-subagent-limit")).toBeNull();
});
