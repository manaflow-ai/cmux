// l10n-allow-file: test fixture prompts and chat names, not shipped UI.
// acpmux's agent pair guard (#21975) pauses two agent chats that keep messaging each other without
// progress and records `agent_pair_paused`, `agent_pair_held`, `agent_pair_resumed`,
// `agent_pair_released` and `agent_pair_dropped` (cmux-tui/crates/acpmux/src/hub/agent_pairs.rs).
// Without a row for them the person saw nothing: the other agent's messages stopped arriving with
// no say why and no way to let them through. The pause is one quiet row that names the peer and
// why (back and forth, the same message, the cap, a release that failed), lists the held messages
// and offers Resume (`_acpmux/agent_pair_resume`); once the pair resumes it is one line counting
// what acpmux delivered. A held message never draws as a prompt.
//
// Review of #22309 found: a re-pause after a failed release drew "went back and forth 0 times"
// with nothing held; the cap read as back and forth; a resent held message counted twice;
// released and dropped messages were never settled; Resume named the selected chat during a
// switch hold instead of the one on screen; and a double click sent Resume twice.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxAgentPair, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { AgentPairNote, spelledWindow } from "../src/agent-session/acpmux/conversation/AgentPairNote";
import { reduceAgentPair } from "../src/agent-session/acpmux/conversation/agentPairs";
import { translate } from "../src/agent-session/acpmux/i18n";
import {
  CHAT,
  OTHER_CHAT,
  PEER,
  START,
  type Step,
  connect,
  dropped,
  fakeDaemon,
  held,
  paused,
  pairs,
  record,
  released,
  resumed,
} from "./support/agentPairDaemon";

/// What a row says, compactly: why, what it still holds, what settled, whether it resumed.
const summary = (pair: AcpmuxAgentPair) => ({
  reason: pair.reason,
  count: pair.count,
  held: pair.held.map((item) => item.promptId),
  released: pair.released,
  dropped: pair.dropped,
  resumed: pair.resumed ?? false,
});

test("a pause is one row that lists the held messages and collapses when the pair resumes", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Ask the reviewer to sign off" }],
      ["mux", "turn_result", { status: "completed" }],
      paused(),
      held("p-9", "LGTM? Please confirm again."),
    ]),
  );
  const { rows } = await connect(daemon);
  expect(pairs(rows())).toEqual([
    {
      peer: PEER,
      peerName: "Reviewer",
      reason: "alternating",
      count: 10,
      windowSecs: 600,
      held: [{ promptId: "p-9", text: "LGTM? Please confirm again." }],
      released: 0,
      dropped: 0,
    },
  ]);
  daemon.push(record([held("p-10", "Still waiting on your sign-off.")], 5));
  expect(pairs(rows())[0]!.held.map((item) => item.text)).toEqual([
    "LGTM? Please confirm again.",
    "Still waiting on your sign-off.",
  ]);
  // A held message is not a prompt: the only user row is the person's own.
  expect(
    rows()
      .filter((row) => row.kind === "user")
      .map((row) => row.text),
  ).toEqual(["Ask the reviewer to sign off"]);

  daemon.push(record([resumed(2), released("p-9"), released("p-10")], 6));
  expect(pairs(rows()).map(summary)).toEqual([
    { reason: "alternating", count: 10, held: [], released: 2, dropped: 0, resumed: true },
  ]);
});

test("a resent held message counts once", async () => {
  const daemon = fakeDaemon(record([paused(), held("p-9", "again"), held("p-9", "again")]));
  const { rows } = await connect(daemon);
  daemon.push(record([held("p-9", "again"), held("p-10", "and again"), held("p-10", "and again")], 4));
  expect(pairs(rows()).map(summary)).toEqual([
    { reason: "alternating", count: 10, held: ["p-9", "p-10"], released: 0, dropped: 0, resumed: false },
  ]);
});

test("a released message counts as delivered; a dropped one is counted apart", async () => {
  const daemon = fakeDaemon(
    record([paused(), held("p-9", "one"), held("p-10", "two"), held("p-11", "three"), resumed(3)]),
  );
  const { rows } = await connect(daemon);
  daemon.push(record([released("p-9"), dropped("p-10"), released("p-11")], 6));
  expect(pairs(rows()).map(summary)).toEqual([
    { reason: "alternating", count: 10, held: [], released: 2, dropped: 1, resumed: true },
  ]);
  // A dropped message named by the other side (no held record here) still counts.
  daemon.push(record([dropped("p-12")], 9));
  expect(pairs(rows())[0]!.dropped).toBe(2);
});

test("a re-pause after a failed release carries what is still held, live and on reload", async () => {
  const steps: Step[] = [
    paused(),
    held("p-9", "one"),
    held("p-10", "two"),
    held("p-11", "three"),
    resumed(3),
    released("p-9"),
    paused({ reason: "release_failed", promptId: "p-10", error: "the turn failed", count: undefined }),
  ];
  const expected: ReturnType<typeof summary>[] = [
    { reason: "alternating", count: 10, held: [], released: 1, dropped: 0, resumed: true },
    { reason: "release_failed", count: 0, held: ["p-10", "p-11"], released: 0, dropped: 0, resumed: false },
  ];

  const live = fakeDaemon(record(steps.slice(0, 5)));
  const { rows: liveRows } = await connect(live);
  live.push(record(steps.slice(5), 6));
  expect(pairs(liveRows()).map(summary)).toEqual(expected);
  expect(pairs(liveRows())[1]!.error).toBe("the turn failed");

  const { rows: reloaded } = await connect(fakeDaemon(record(steps)));
  expect(pairs(reloaded()).map(summary)).toEqual(expected);

  // Resuming again and delivering the rest settles the new row.
  live.push(record([resumed(2), released("p-10"), released("p-11")], 8));
  expect(pairs(liveRows()).map(summary)[1]).toEqual({
    reason: "release_failed",
    count: 0,
    held: [],
    released: 2,
    dropped: 0,
    resumed: true,
  });
});

test("the cap is its own reason, with its window", async () => {
  const { rows } = await connect(
    fakeDaemon(record([paused({ reason: "cap", count: 21, windowSecs: 600 }), held("p-9", "x")])),
  );
  expect(pairs(rows()).map((pair) => [pair.reason, pair.count, pair.windowSecs])).toEqual([["cap", 21, 600]]);
});

test("the cap's window is spelled out in the pane language", () => {
  expect(spelledWindow(600, "en")).toBe("10 minutes");
  expect(spelledWindow(60, "en")).toBe("1 minute");
  expect(spelledWindow(7200, "en")).toBe("2 hours");
  expect(spelledWindow(90, "en")).toBe("90 seconds");
  expect(spelledWindow(600, "de")).toBe("10 Minuten");
});

test("records for another peer, or without a pause, change nothing", () => {
  const rows = new Map<string, AcpmuxRow>();
  const at = START;
  expect(reduceAgentPair(rows, { seq: 1, at, kind: "agent_pair_held", msg: { from: PEER, promptId: "a" } })).toBe(true);
  expect(reduceAgentPair(rows, { seq: 2, at, kind: "agent_pair_resumed", msg: { peer: PEER } })).toBe(true);
  expect(reduceAgentPair(rows, { seq: 3, at, kind: "agent_pair_released", msg: { peer: PEER, promptId: "a" } })).toBe(
    true,
  );
  expect(rows.size).toBe(0);
  reduceAgentPair(rows, { seq: 4, at, kind: "agent_pair_paused", msg: { peer: PEER, peerName: "R", count: 3 } });
  reduceAgentPair(rows, { seq: 5, at, kind: "agent_pair_held", msg: { from: "someone-else", promptId: "b" } });
  reduceAgentPair(rows, { seq: 6, at, kind: "agent_pair_resumed", msg: { peer: "someone-else" } });
  reduceAgentPair(rows, { seq: 7, at, kind: "agent_pair_dropped", msg: { peer: "someone-else", promptId: "b" } });
  expect([...rows.values()].map((row) => [row.version, summary(row.agentPair!)])).toEqual([
    [1, { reason: "alternating", count: 3, held: [], released: 0, dropped: 0, resumed: false }],
  ]);
  expect(reduceAgentPair(rows, { seq: 8, at, kind: "turn_started", msg: {} })).toBe(false);
});

test("Resume names the chat on screen while a switch to another chat is still opening", async () => {
  const daemon = fakeDaemon(record([paused(), held("p-9", "again")]));
  const { client } = await connect(daemon);
  const switching = client.select(OTHER_CHAT);
  await new Promise((resolve) => setTimeout(resolve, 0));
  await client.resumeAgentPair(PEER);
  daemon.openOther();
  await switching;
  expect(daemon.resumes().map((request) => request.params)).toEqual([{ sessionId: CHAT, peerSessionId: PEER }]);
});

// ---------- The row itself ----------

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

const pausedPair = (fields: Partial<AcpmuxAgentPair> = {}): AcpmuxAgentPair => ({
  peer: PEER,
  peerName: "Reviewer",
  reason: "alternating",
  count: 10,
  held: [
    { promptId: "p-9", text: "LGTM? Please confirm again." },
    { promptId: "p-10", text: "Still waiting on your sign-off." },
  ],
  released: 0,
  dropped: 0,
  ...fields,
});
const click = (element: Element) => element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
const buttonNamed = (host: HTMLElement, name: string) =>
  [...host.querySelectorAll("button")].find((button) => button.textContent === name);

test("the paused row names the peer and why, counts held messages, and announces it politely", async () => {
  const host = installDom();
  root = createRoot(host);
  await act(async () => root!.render(<AgentPairNote pair={pausedPair()} onResume={async () => undefined} />));
  expect(host.textContent).toContain("Paused messages with Reviewer: the two agents went back and forth 10 times");
  const status = host.querySelector("output, [role='status']")!;
  expect(status.textContent).toContain(translate("agentPair.held", { n: 2 }));
  expect(buttonNamed(host, translate("agentPair.resume"))).toBeDefined();
});

test("each reason has its own sentence", async () => {
  const host = installDom();
  root = createRoot(host);
  const text = async (pair: AcpmuxAgentPair) => {
    await act(async () => root!.render(<AgentPairNote pair={pair} onResume={async () => undefined} />));
    return host.querySelector(".cv-agent-pair__text")!.textContent;
  };
  expect(await text(pausedPair({ reason: "repeating", count: 4, peerName: "" }))).toBe(
    "Paused messages with another agent: the same message was sent 4 times in a row without progress",
  );
  expect(await text(pausedPair({ reason: "cap", count: 21, windowSecs: 600 }))).toBe(
    "Paused messages with Reviewer: the two agents exchanged 21 messages within 10 minutes with no message from you",
  );
  expect(await text(pausedPair({ reason: "release_failed", count: 0, error: "the turn failed" }))).toBe(
    "Paused messages with Reviewer: a held message could not be delivered",
  );
});

test("Show held messages lists each preview, clamps long ones, caps the list, and hides it again", async () => {
  const host = installDom();
  root = createRoot(host);
  const long = "x".repeat(260);
  const many = Array.from({ length: 25 }, (_, index) => ({ promptId: `p-${index}`, text: `message ${index}` }));
  await act(async () =>
    root!.render(<AgentPairNote pair={pausedPair({ held: [{ promptId: "long", text: long }, ...many] })} />),
  );
  const toggle = buttonNamed(host, "Show held messages")!;
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  await act(async () => click(toggle));
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  expect(toggle.textContent).toBe("Hide held messages");
  const list = host.querySelector(".cv-agent-pair__held")!;
  expect(toggle.getAttribute("aria-controls")).toBe(list.id);
  const items = [...list.querySelectorAll("li")].map((item) => item.textContent!);
  expect(items).toHaveLength(21);
  expect(items[0]!.length).toBeLessThanOrEqual(201);
  expect(items[0]!.endsWith("…")).toBe(true);
  expect(items[1]).toBe("message 0");
  expect(items[20]).toBe("and 6 more");
  await act(async () => click(toggle));
  expect(host.querySelector(".cv-agent-pair__held")).toBeNull();
});

test("a resumed pair is one line without Resume that counts delivered and dropped messages", async () => {
  const host = installDom();
  root = createRoot(host);
  const render = (fields: Partial<AcpmuxAgentPair>) =>
    act(async () =>
      root!.render(<AgentPairNote pair={pausedPair({ peerName: "Deploy", resumed: true, ...fields })} />),
    );
  await render({ held: [], released: 0 });
  expect(host.textContent).toBe("Resumed messages with Deploy");
  expect(host.querySelector("button")).toBeNull();
  await render({ held: [], released: 2 });
  expect(host.textContent).toBe("Resumed messages with Deploy, 2 delivered");
  await render({ held: [], released: 2, dropped: 1 });
  expect(host.textContent).toBe("Resumed messages with Deploy, 2 delivered1 not delivered");
});

test("a double click sends Resume once; a failed Resume says so and can be pressed again", async () => {
  const host = installDom();
  root = createRoot(host);
  let calls = 0;
  let fail = true;
  await act(async () =>
    root!.render(
      <AgentPairNote
        pair={pausedPair()}
        onResume={() => {
          calls += 1;
          return fail ? Promise.reject(new Error("refused")) : Promise.resolve();
        }}
      />,
    ),
  );
  const resume = () => buttonNamed(host, translate("agentPair.resume"))!;
  await act(async () => {
    click(resume());
    click(resume());
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(calls).toBe(1);
  expect(host.querySelector("output, [role='status']")!.textContent).toContain(translate("agentPair.resumeFailed"));
  expect(resume().disabled).toBe(false);
  fail = false;
  await act(async () => {
    click(resume());
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(calls).toBe(2);
});
