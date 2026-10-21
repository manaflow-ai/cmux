// cx-v9k2f: the Agent Activity page's lanes view, the coordinator's view of every acpmux session.
// What needs a person comes first: an agent dead on "Credit balance too low" says so with the
// error, one waiting on a permission says so, idle ones say for how long, and a click opens the
// chat. About 25 lanes sat idle for hours unnoticed on 2026-10-13, some dead on out-of-credit
// errors. Off by default (Labs preview features): without lanes the page is the computer-use view.
import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { Lane } from "../src/agent-activity/lanes";
import type { ActivityState } from "../src/agent-activity/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const hours = (n: number) => Date.now() - n * 3_600_000;
const lane = (id: string, state: Lane["state"], extra: Partial<Lane> = {}): Lane => ({
  id,
  name: id,
  title: id,
  state,
  since: hours(1),
  ...extra,
});

/** One lane per state, on this Mac and an acpmux peer, under a coordinator and on their own. */
const lanes: Lane[] = [
  lane("chief", "working", { title: "Coordinator", since: hours(0.1) }),
  lane("op-busy", "working", { parent: "chief", since: hours(0.5), harness: "codex", step: "Run the guard tests" }),
  lane("op-idle-long", "idle", { parent: "chief", since: hours(5) }),
  lane("op-idle-short", "idle", { parent: "chief", since: hours(1) }),
  lane("op-broke", "failed", { parent: "chief", since: hours(3), error: "Credit balance too low" }),
  lane("op-asks", "input", { parent: "chief", since: hours(0.2) }),
  lane("scratch", "idle", { since: hours(2) }),
  lane("mini-1", "lost", { name: "mini/op-gone", title: "op-gone", peer: "mini", since: hours(4) }),
];

let dispatched: unknown[] = [];

async function render(state: Partial<ActivityState>) {
  const { createRoot } = await import("react-dom/client");
  const { ActivityView } = await import("../src/agent-activity/view");
  const { initialActivityState } = await import("../src/agent-activity/model");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(<ActivityView state={{ ...initialActivityState(), ...state }} dispatch={(a) => dispatched.push(a)} />),
  );
}

const rows = () => [...host.querySelectorAll<HTMLElement>("[data-lane]")];
const row = (id: string) => rows().find((r) => r.dataset.lane === id)!;

beforeEach(() => {
  dispatched = [];
});

describe("Agent Activity lanes", () => {
  test("lists every session by machine, then coordinator, with what needs a person first", async () => {
    await render({ lanes });
    const machines = [...host.querySelectorAll(".lanes [data-machine]")].map((m) => m.querySelector("h2")?.textContent);
    expect(machines).toEqual(["This Mac", "mini"]);
    expect(rows().map((r) => r.dataset.lane)).toEqual([
      "chief",
      "op-broke",
      "op-asks",
      "op-idle-long",
      "op-idle-short",
      "op-busy",
      "scratch",
      "mini-1",
    ]);
    const groups = [...host.querySelectorAll(".lanes [data-machine='local'] h3")].map((h) => h.textContent);
    expect(groups).toEqual(["Coordinator", "On their own"]);
  });

  test("says each state, for how long, and a failed lane's error", async () => {
    await render({ lanes });
    expect(row("op-busy").textContent).toContain("Working · 30m");
    expect(row("op-asks").textContent).toContain("Waiting on you · 12m");
    expect(row("op-idle-long").textContent).toContain("Idle · 5h");
    expect(row("op-broke").textContent).toContain("Failed · 3h");
    expect(row("op-broke").textContent).toContain("Credit balance too low");
    expect(row("mini-1").textContent).toContain("Lost · 4h");
    expect(row("op-broke").dataset.state).toBe("failed");
  });

  test("shows each lane's harness and current step under its title; an error takes the step's place", async () => {
    await render({ lanes: [...lanes.slice(0, 4), { ...lanes[4], step: "Retrying the build" }, ...lanes.slice(5)] });
    expect(row("op-busy").querySelector(".lane-harness")?.textContent).toBe("codex");
    expect(row("op-busy").querySelector(".lane-step")?.textContent).toBe("Run the guard tests");
    expect(row("op-broke").querySelector(".lane-step")).toBeNull();
    expect(row("op-idle-long").querySelector(".lane-detail")).toBeNull();
  });

  test("the filter finds a lane by its current step", async () => {
    await render({ lanes, filter: "guard" });
    expect(rows().map((r) => r.dataset.lane)).toEqual(["op-busy"]);
  });

  test("counts the sessions that need a person", async () => {
    await render({ lanes });
    expect(host.querySelector(".lanes-attention")?.textContent).toBe("Needs you: 3");
  });

  test("a click opens that session's chat", async () => {
    await render({ lanes });
    act(() => row("op-broke").click());
    expect(dispatched).toContainEqual({ type: "jump", id: "op-broke" });
  });

  test("the filter finds a lane by its error text, and says when nothing matches", async () => {
    await render({ lanes, filter: "credit" });
    expect(rows().map((r) => r.dataset.lane)).toEqual(["op-broke"]);
    expect(host.querySelector(".lanes-attention")?.textContent).toBe("Needs you: 3");
    await render({ lanes, filter: "no such lane" });
    expect(host.querySelector(".lanes .empty")?.textContent).toBe("No matching sessions");
  });

  test("Computer use switches to the computer-use view and back", async () => {
    await render({ lanes });
    const tab = (name: string) =>
      [...host.querySelectorAll<HTMLInputElement>(".page-view input")].find(
        (i) => i.labels?.[0]?.textContent === name,
      )!;
    act(() => tab("Computer use").click());
    expect(host.querySelector(".lanes")).toBeNull();
    act(() => tab("Lanes").click());
    expect(host.querySelector(".lanes")).not.toBeNull();
  });

  test("with the lanes view off (no lanes) the page is the computer-use view alone", async () => {
    await render({ lanes: undefined });
    expect(host.querySelector(".lanes")).toBeNull();
    expect(host.querySelector(".page-view")).toBeNull();
  });
});
