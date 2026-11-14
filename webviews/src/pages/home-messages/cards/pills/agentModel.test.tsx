// The started-agent pills and the agent pane, ported from Swift `HomeAgentPills`,
// `HomeAgentChatContent` and `HomeAgentPane`: each state draws its own mark and status, a report
// is unread until its tab shows, and the pane's tabs open, select and close as the Swift pane's.
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { cardStrings } from "../strings";
import { AgentChat } from "./AgentChat";
import { AgentPills } from "./AgentPills";
import {
  agentChatContent,
  agentDuration,
  agentPills,
  closeAgent,
  EMPTY_PANE,
  openAgent,
  openAgentOutside,
  sendToAgent,
  type AgentThread,
  type AgentThreadSource,
} from "./agentModel";

const strings = cardStrings(["en"]);

describe("agentPills", () => {
  test("each state keeps its state; unknown states work; a report is unread by default", () => {
    const pills = agentPills({
      peers: ["a1", "a2", "a3", "a4", "a5"],
      titles: ["Fix", "Build", "Audit", "Scroll", "Odd"],
      states: ["told", "reported", "stopped", "queued", "mystery"],
    });
    expect(pills.map((pill) => pill.state)).toEqual(["told", "reported", "stopped", "queued", "told"]);
    expect(pills.map((pill) => pill.unread)).toEqual([false, true, false, false, false]);
  });

  test("a seen report has no dot; titles that do not match the peers show the ids", () => {
    const pills = agentPills({ peers: ["a1", "a2"], titles: ["only one"], states: ["reported"], unread: [false] });
    expect(pills.map((pill) => [pill.title, pill.state, pill.unread])).toEqual([
      ["a1", "reported", false],
      ["a2", "told", false],
    ]);
  });

  test("durations read as the Swift formatter's", () => {
    expect(agentDuration(48)).toBe("48s");
    expect(agentDuration(335)).toBe("5m 35s");
    expect(agentDuration(3720)).toBe("1h 2m");
  });
});

const thread = (patch: Partial<AgentThread> = {}): AgentThread => ({
  peer: "a12",
  title: "Sidebar alignment fix",
  state: "told",
  task: "Fix the sidebar alignment.",
  entries: [{ id: "1", sender: "chief", text: "Bump your job." }],
  startedAt: Date.UTC(2026, 10, 6, 9, 0, 0),
  workspaceLink: "cmux://chief/0a1b2c3d/session/s-81",
  ...patch,
});

describe("agentChatContent", () => {
  test("working, queued, reported and stopped each have their status and time line", () => {
    const now = Date.UTC(2026, 10, 6, 9, 5, 35);
    const at = (state: AgentThread["state"], endedAt?: number) =>
      agentChatContent(thread({ state, endedAt }), now, strings);
    expect([at("told").status, at("told").workedFor]).toEqual(["Working", "Working for 5m 35s"]);
    expect([at("queued").status, at("queued").workedFor]).toEqual(["Queued", "Queued for 5m 35s"]);
    const reported = at("reported", Date.UTC(2026, 10, 6, 9, 1, 12));
    expect([reported.status, reported.workedFor, reported.details.length]).toEqual([
      "Reported",
      "Worked for 1m 12s",
      2,
    ]);
    expect(at("stopped", now).status).toBe("Stopped without a report");
  });

  test("a moved session opens where it runs now; another session's move changes nothing", () => {
    const moved = agentChatContent(thread(), 0, strings, {
      peer: "a12",
      session: "s-81",
      place: "cmux-mini",
      moveEpoch: 1,
    });
    expect([moved.place, moved.workspaceLink]).toEqual(["cmux-mini", "cmux://session/s-81"]);
    const other = agentChatContent(thread(), 0, strings, { peer: "a12", session: "s-99", place: "x", moveEpoch: 1 });
    expect([other.place, other.workspaceLink]).toEqual([undefined, "cmux://chief/0a1b2c3d/session/s-81"]);
  });
});

function source(threads: Record<string, AgentThread>) {
  const seen: string[] = [];
  const sent: [string, string][] = [];
  const src: AgentThreadSource = {
    thread: (peer) => threads[peer],
    markSeen: (peer) => seen.push(peer),
    send: (text, peer) => sent.push([peer, text]),
  };
  return { src, seen, sent };
}

describe("agent pane", () => {
  test("opening adds a tab at the end or selects its tab, and marks it seen", () => {
    const { src, seen } = source({});
    let pane = openAgent(EMPTY_PANE, "a1", src);
    pane = openAgent(pane, "a2", src);
    pane = openAgent(pane, "a1", src);
    expect(pane).toEqual({ tabs: ["a1", "a2"], selected: "a1" });
    expect(seen).toEqual(["a1", "a2", "a1"]);
  });

  test("closing shows the next tab, else the previous, and none left hides the pane", () => {
    const { src } = source({});
    let pane = ["a1", "a2", "a3"].reduce((state, peer) => openAgent(state, peer, src), EMPTY_PANE);
    pane = closeAgent(openAgent(pane, "a2", src), "a2", src);
    expect(pane).toEqual({ tabs: ["a1", "a3"], selected: "a3" });
    pane = closeAgent(pane, "a3", src);
    expect(pane).toEqual({ tabs: ["a1"], selected: "a1" });
    expect(closeAgent(pane, "a1", src)).toEqual({ tabs: [] });
  });

  test("a click opens the agent beside Home when it can, else in the pane", () => {
    const { src, seen } = source({ a12: thread() });
    const [same, outside] = openAgentOutside(EMPTY_PANE, "a12", src, () => true);
    expect([same, outside, seen]).toEqual([EMPTY_PANE, true, ["a12"]]);
    const [pane, beside] = openAgentOutside(EMPTY_PANE, "a12", src, () => false);
    expect([pane, beside]).toEqual([{ tabs: ["a12"], selected: "a12" }, false]);
  });

  test("the composer sends trimmed words to an open tab only", () => {
    const { src, sent } = source({});
    const pane = openAgent(EMPTY_PANE, "a1", src);
    sendToAgent(pane, "a1", "  hello  ", src);
    sendToAgent(pane, "a1", "   ", src);
    sendToAgent(pane, "a9", "lost", src);
    expect(sent).toEqual([["a1", "hello"]]);
  });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

function render(node: React.ReactNode): HTMLElement {
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
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(node));
  return host;
}

describe("AgentPills", () => {
  test("draws one pill per agent with its state, status and dot, and a click opens it", () => {
    const opened: [string, boolean][] = [];
    const host = render(
      <AgentPills
        row={{
          peers: ["a1", "a2", "a3", "a4"],
          titles: ["Fix", "Build", "Audit", "Scroll"],
          states: ["told", "reported", "stopped", "queued"],
        }}
        strings={strings}
        onOpen={(peer, command) => opened.push([peer, command])}
      />,
    );
    const pills = [...host.querySelectorAll<HTMLButtonElement>(".hm-pill")];
    expect(pills.map((pill) => pill.dataset.state)).toEqual(["told", "reported", "stopped", "queued"]);
    expect(pills.map((pill) => pill.getAttribute("aria-label"))).toEqual([
      "Fix, Working",
      "Build, Reported",
      "Audit, Stopped without a report",
      "Scroll, Queued",
    ]);
    expect(pills.map((pill) => pill.querySelector(".hm-pill__dot") !== null)).toEqual([false, true, false, false]);
    act(() => {
      pills[1]!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, metaKey: true }));
    });
    expect(opened).toEqual([["a2", true]]);
  });

  test("the two-line shape adds the status line", () => {
    const host = render(
      <AgentPills
        row={{ peers: ["a1"], titles: ["Fix"], states: ["reported"] }}
        shape="twoLine"
        strings={strings}
        onOpen={() => {}}
      />,
    );
    expect(host.querySelector(".hm-pill__status")?.textContent).toBe("Reported · a1");
  });
});

describe("AgentChat", () => {
  const content = (messages: { sender: "agent" | "chief" | "you"; text: string }[]) => ({
    peer: "a1",
    title: "Fix",
    status: "Working",
    task: "",
    workedFor: "",
    details: [],
    messages,
  });
  const bubbles = (host: HTMLElement) =>
    [...host.querySelectorAll(".hm-agent-chat__out[data-sender=you] .hm-agent-chat__bubble")].map(
      (node) => node.textContent ?? "",
    );

  test("a sent message stays through a refresh until the store echoes it, once", () => {
    const sends: string[] = [];
    const draw = (messages: { sender: "agent" | "chief" | "you"; text: string }[]) => (
      <AgentChat content={content(messages)} strings={strings} actions={{ sent: (text) => sends.push(text) }} />
    );
    const host = render(draw([{ sender: "you", text: "go" }]));
    const field = host.querySelector("form input")! as HTMLInputElement;
    const form = host.querySelector("form")!;
    act(() => {
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
      setter.call(field, "go");
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    act(() => {
      form.dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
    });
    expect(bubbles(host).filter((text) => text === "go").length).toBe(2);
    expect(sends).toEqual(["go"]);
    // A refresh that does not carry it yet keeps it.
    act(() =>
      root!.render(
        draw([
          { sender: "you", text: "go" },
          { sender: "agent", text: "ok" },
        ]),
      ),
    );
    expect(bubbles(host).filter((text) => text === "go").length).toBe(2);
    // The echo replaces it: no doubled bubble.
    act(() =>
      root!.render(
        draw([
          { sender: "you", text: "go" },
          { sender: "agent", text: "ok" },
          { sender: "you", text: "go" },
        ]),
      ),
    );
    expect(bubbles(host).filter((text) => text === "go").length).toBe(2);
  });
});
