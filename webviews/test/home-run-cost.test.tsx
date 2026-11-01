// A run's dollar figure (Leo 2026-10-21: "whats the $ supposed to be? we're all using subrouter2
// anyways"). Claude Code reports what a turn would cost at pay-per-token API prices, even on a
// subscription or through a router, where nobody pays it. The run card shows tokens instead; the run
// sheet keeps the figure, labelled as API prices with a tooltip that says what it is.
import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import * as agentRows from "../src/agent-session/acpmux/conversation/AgentMessageRow";
import { RunCard } from "../src/pages/home-channels/RunCard";
import { RunSheet } from "../src/pages/home-channels/RunSheet";
import table from "../src/pages/home-channels/generated/strings.json";
import paneTable from "../src/pages/home-channels/generated/pane-strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  saved.set("__cmuxPaneStrings", scope.__cmuxPaneStrings);
  scope.__cmuxPaneStrings = paneTable;
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
  mock.restore();
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
  expect(container.textContent).not.toContain("message.");
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

const reportStep = {
  id: "report:a1:1:0",
  seq: 1,
  rev: 1,
  at: 1,
  kind: "note" as const,
  text: "[a1] Verified.",
  attachments: [],
  links: [],
};

test("a multi-answer report follows one loaded question as the history window changes", async () => {
  const { RunBook } = await import("../src/pages/home-channels/runs");
  const book = new RunBook();
  const first = { id: "q1", conversation: "c1" } as never;
  const second = { id: "q2", conversation: "c1" } as never;
  const { turn: _turn, ...silent } = run;
  const report = { ...silent, answers: ["q1", "q2"], stepCount: 1 } as never;
  book.setLoadedMessages([second]);
  book.setSteps(report, [reportStep], true);
  expect(book.liveFor(second).map((entry) => entry.run.id)).toEqual(["r1"]);
  expect(book.liveFor(first)).toHaveLength(0);
  book.setLoadedMessages([first, second]);
  expect([...book.liveFor(first), ...book.liveFor(second)]).toHaveLength(1);
  book.setLoadedMessages([second]);
  expect(book.liveFor(second)).toHaveLength(1);
  expect(book.liveFor(first)).toHaveLength(0);
});

test("loaded questions and replies keep reports through newer summaries until their window leaves", async () => {
  const { RunBook } = await import("../src/pages/home-channels/runs");
  const book = new RunBook();
  const question = { id: "question", conversation: "c1" } as never;
  const reply = { id: "reply", conversation: "c1", author: "chief", clientMessageId: "t1" } as never;
  book.setLoadedMessages([question, reply]);
  book.setSteps(
    { ...run, id: "report", turn: undefined, answers: ["question"], stepCount: 1 } as never,
    [reportStep],
    true,
  );
  book.setSteps({ ...run, stepCount: 1 } as never, [reportStep], true);
  book.setRuns(
    Array.from({ length: 450 }, (_, index) => ({
      ...run,
      id: `newer-${index}`,
      turn: `turn-${index}`,
      updatedAt: 100_000 + index,
    })) as never,
  );
  expect(book.liveFor(question).map((entry) => entry.run.id)).toEqual(["report"]);
  expect(book.forReply(reply)?.steps).toEqual([reportStep]);
  expect(book.get("c1", "chief", "newer-0")).toBeUndefined();
  expect(book.get("c1", "chief", "newer-449")).toBeDefined();
  book.setLoadedMessages([]);
  expect(book.get("c1", "chief", "report")).toBeUndefined();
  expect(book.forReply(reply)).toBeUndefined();
});

for (const [reason, expected] of [
  ["a1 was cancelled", "message.notDeliveredStopped"],
  ["a1's cloud VM was deleted", "message.notDeliveredNoAgent"],
]) {
  test(`a folded refused tell shows its localized reason: ${reason}`, async () => {
    const container = installDom();
    const paneStrings = createStrings(paneTable, ["en"]);
    await render(
      container,
      <RunCard
        entry={{
          run: { ...run, stepCount: 1 } as never,
          complete: true,
          steps: [
            {
              ...reportStep,
              id: `refused:${reason}`,
              kind: "tool",
              status: "done",
              tool: {
                name: "mcp__optchat__tell",
                input: { id: "a1", message: "Check it." },
                output: `outcome: refused. ${reason}`,
                files: [],
              },
            },
          ],
        }}
        strings={strings}
        onOpen={() => {}}
        onLoad={() => {}}
      />,
    );
    expect(container.querySelector(".lg-run-toggle")?.getAttribute("aria-expanded")).toBe("false");
    expect(container.querySelector('[data-delivery="failed"]')?.textContent).toContain(paneStrings.t(expected));
    expect(container.textContent).not.toContain("message.");
  });
}

test("a collapsed card does not reprocess historical inputs when a step is appended", async () => {
  const container = installDom();
  let serializations = 0;
  const preview = spyOn(agentRows, "messagePreview");
  const longText = "Earlier assignment\n" + "Large historical message\n".repeat(5000);
  const old = {
    id: "old-tell",
    seq: 1,
    at: 1,
    rev: 1,
    kind: "tool" as const,
    status: "done" as const,
    attachments: [],
    links: [],
    tool: {
      name: "mcp__optchat__tell",
      files: [],
      input: {
        toJSON: () => {
          serializations++;
          return { id: "a1", message: longText };
        },
      },
    },
  };
  const props = { strings, onOpen: () => {}, onLoad: () => {} };
  const report = { ...old, id: "report:old", kind: "note" as const, tool: undefined, text: `[a1] ${longText}` };
  await render(container, <RunCard {...props} entry={{ ...entry, steps: [old, report] }} />);
  const before = serializations;
  const previewsBefore = preview.mock.calls.length;
  expect(previewsBefore).toBeGreaterThan(0);
  expect(before).toBeGreaterThan(0);
  await act(async () =>
    root!.render(
      <RunCard
        {...props}
        entry={{
          ...entry,
          run: { ...run, rev: 2 } as never,
          steps: [
            old,
            report,
            {
              id: "new",
              seq: 2,
              at: 2,
              rev: 1,
              kind: "thought",
              text: "Working",
              attachments: [],
              links: [],
            },
          ],
        }}
      />,
    ),
  );
  expect(serializations).toBe(before);
  expect(preview.mock.calls.length).toBe(previewsBefore);
  preview.mockRestore();
  expect(container.textContent).toContain("Earlier assignment");
});
