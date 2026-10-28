// A run's dollar figure (Leo 2026-10-21: "whats the $ supposed to be? we're all using subrouter2
// anyways"). Claude Code reports what a turn would cost at pay-per-token API prices, even on a
// subscription or through a router, where nobody pays it. The run card shows tokens instead; the run
// sheet keeps the figure, labelled as API prices with a tooltip that says what it is.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RunCard } from "../src/pages/home-channels/RunCard";
import { RunSheet } from "../src/pages/home-channels/RunSheet";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const strings = createStrings(table, ["en"]);
const run = {
  id: "r1",
  conversation: "c1",
  author: "chief",
  status: "done",
  startedAt: 0,
  endedAt: 60_000,
  updatedAt: 60_000,
  rev: 1,
  stepCount: 2,
  turn: "t1",
  answers: [],
  usage: { input: 1_840, output: 612, cacheRead: 46_200 },
  costUsd: 0.0421,
};
const entry = { run: run as never, steps: [], complete: true };

async function render(container: HTMLElement, node: React.ReactNode) {
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
}

test("the run card shows tokens, never a dollar figure", async () => {
  const container = installDom();
  await render(container, <RunCard entry={entry} strings={strings} onOpen={() => {}} onLoad={() => {}} />);
  const metas = [...container.querySelectorAll(".lg-run-meta")].map((meta) => meta.textContent);
  expect(metas).toEqual([strings.format("run.steps.many", "2"), strings.format("run.tokens", "49k")]);
  expect(container.querySelector(".lg-run-bar")?.textContent).not.toContain("$");
});

test("the run sheet labels its dollar figure as API prices and says what it is", async () => {
  const container = installDom();
  await render(
    container,
    <RunSheet entry={entry} people={new Map()} strings={strings} place="Chief" onClose={() => {}} onLoad={() => {}} />,
  );
  const cost = [...container.querySelectorAll(".lg-sheet-meta span")].find((span) => span.textContent?.includes("$"));
  expect(cost?.textContent).toBe(strings.format("run.cost", "$0.04"));
  expect(cost?.textContent).not.toBe("$0.04");
  expect(cost?.getAttribute("title")).toBe(strings.t("run.cost.hint"));
});

// Messages remain reachable when the run is folded and after unrelated tool steps.
test("a folded Chief run keeps outgoing messages and incoming reports visible", async () => {
  const container = installDom();
  const text = "Please verify the result. ".repeat(30) + "Keep this last sentence.";
  const base = { at: 1, rev: 1, attachments: [], links: [] };
  const steps = [
    {
      ...base,
      id: "tool:tell",
      seq: 1,
      kind: "tool",
      status: "done",
      tool: {
        name: "mcp__optchat__tell",
        title: "Tell a1",
        input: { id: "a1", message: text },
        files: [],
      },
    },
    {
      ...base,
      id: "report:a1:1:0",
      seq: 2,
      kind: "note",
      text: "[a1] Verified the result. All checks passed.",
    },
    ...[3, 4, 5, 6].map((seq) => ({
      ...base,
      id: `tool:${seq}`,
      seq,
      kind: "tool",
      status: "done",
      tool: {
        name: "Bash",
        input: { command: "pwd" },
        files: [],
      },
    })),
  ];
  await render(
    container,
    <RunCard
      entry={{ run: { ...run, stepCount: steps.length } as never, steps: steps as never, complete: true }}
      strings={strings}
      onOpen={() => {}}
      onLoad={() => {}}
    />,
  );
  expect(container.querySelector(".lg-run-toggle")?.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelectorAll(".cv-agentmsg").length).toBe(2);
  expect(container.textContent).toContain("Verified the result.");
  const message = container.querySelector('[data-direction="sent"]')!;
  await act(async () => (message.querySelector(".cv-agentmsg__toggle") as HTMLElement).click());
  expect(message.textContent).toContain("Keep this last sentence.");
  await act(async () => (container.querySelector(".lg-run-toggle") as HTMLElement).click());
  expect(container.querySelectorAll('[data-direction="sent"]').length).toBe(1);
});

test("a folded restored Chief run loads its messages without opening", async () => {
  const container = installDom();
  const loaded: unknown[] = [];
  await render(
    container,
    <RunCard
      entry={{ ...entry, complete: false }}
      strings={strings}
      onOpen={() => {}}
      onLoad={(r) => loaded.push(r.id)}
    />,
  );
  expect(loaded).toEqual([run.id]);
});

test("a completed silent Chief run exposes messages beside its question after loading", async () => {
  const { RunBook } = await import("../src/pages/home-channels/runs");
  const book = new RunBook();
  const silent = { ...run, answers: ["question"] } as never;
  const question = { id: "question", conversation: "c1" } as never;
  book.setRuns([silent]);
  expect(book.liveFor(question)).toHaveLength(0);
  book.setSteps(
    silent,
    [
      {
        id: "report:a1:1:0",
        seq: 1,
        rev: 1,
        at: 1,
        kind: "note",
        text: "[a1] Verified.",
        attachments: [],
        links: [],
      },
    ],
    true,
  );
  expect(book.liveFor(question)).toHaveLength(1);
  book.noteMessages([{ conversation: "c1", author: "chief", clientMessageId: "t1" } as never]);
  expect(book.liveFor(question)).toHaveLength(0);
});

test("a newer run summary invalidates loaded steps so missed reports can be restored", async () => {
  const { RunBook } = await import("../src/pages/home-channels/runs");
  const book = new RunBook();
  const summary = { ...run, stepCount: 0 } as never;
  book.setSteps(summary, [], true);
  expect(book.get("c1", "chief", "r1")?.complete).toBe(true);
  book.setRuns([{ ...run, rev: 2, stepCount: 1 } as never]);
  expect(book.get("c1", "chief", "r1")?.complete).toBe(false);
});
