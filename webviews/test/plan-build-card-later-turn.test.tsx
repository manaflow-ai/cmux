// A run's later turn on the builds card (cmux#38892 review, F2): a message sent to a run that was
// done starts a turn whose `turn_started` record says it works again, and a diff read from before
// that record never says it is done, so its Keep waits for the turn to end.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PlanBuild } from "../src/agent-session/acpmux/planBuild/planBuild";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  const { window } = dom;
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

/// The read acpmux answers for run `c1`, by its status.
const reply = (status: string) => ({
  buildId: "run-1",
  builds: [
    { sessionId: "c1", status, added: 1, removed: 0, files: [{ path: "NOTICE", added: 1, removed: 0 }] },
    { sessionId: "c2", status: "done", added: 1, removed: 0, files: [{ path: "NOTICE", added: 1, removed: 0 }] },
  ],
});

const started: PlanBuild = {
  buildId: "run-1",
  target: "prompt",
  builds: [
    { sessionId: "c1", harness: "claude", model: "claude-opus-5-5", state: "running" },
    { sessionId: "c2", harness: "codex", model: "gpt-6", state: "running" },
  ],
  archived: [],
  turnsEnded: 0,
};

const column = (id: string) =>
  host.querySelector<HTMLElement>(`[data-open-session="${id}"]`)!.closest<HTMLElement>(".acpmux-plan-builds-column")!;
const keep = (id: string) => column(id).querySelector<HTMLButtonElement>(".acpmux-plan-builds-keep")!;

test("a later turn of a done run shows it working, and an older read never says it is done", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PlanBuildCard } = await import("../src/agent-session/acpmux/planBuild/PlanBuildCard");
  const { planBuildChildStarted, planBuildChildEnded } =
    await import("../src/agent-session/acpmux/planBuild/planBuild");
  // Each read waits until the test answers it.
  const answers: ((status: string) => void)[] = [];
  const compare = () => new Promise<unknown>((resolve) => answers.push((status) => resolve(reply(status))));
  const draw = (build: PlanBuild) =>
    act(() =>
      root!.render(<PlanBuildCard build={build} sessionId="parent" onOpen={() => undefined} compare={compare} />),
    );
  root = createRoot(host);

  // The first turn ended before the card had its records: acpmux's read says done.
  await draw(started);
  answers.shift()!("done");
  await settle();
  expect(column("c1").dataset.state).toBe("done");
  expect(keep("c1").disabled).toBe(false);

  // The person sends c1 another message: its `turn_started` record comes while no new read is back.
  const again = planBuildChildStarted(started, { event: "turn_started", childSessionId: "c1" })!;
  await draw(again);
  expect(column("c1").dataset.state).toBe("running");
  expect(keep("c1").disabled).toBe(true);
  // The record starts a new read, which acpmux answers while the turn works.
  expect(answers.length).toBe(1);
  answers.shift()!("working");
  await settle();
  expect(column("c1").dataset.state).toBe("running");
  expect(keep("c1").disabled).toBe(true);

  // The turn ends: done, and Keep is back.
  const ended = planBuildChildEnded(again, { event: "turn_ended", childSessionId: "c1", state: "done" })!;
  await draw(ended);
  expect(column("c1").dataset.state).toBe("done");
  expect(keep("c1").disabled).toBe(false);
});
