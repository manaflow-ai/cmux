import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PresentationToggle, readPresentation } from "../src/pages/home-channels/presentation";
import { runBlocks } from "../src/pages/home-channels/runBlocks";
import { RunTranscript } from "../src/pages/home-channels/RunTranscript";
import { RunsContext } from "../src/pages/home-channels/RunCard";
import { MessageRow } from "../src/pages/home-channels/MessageRow";
import { RunBook } from "../src/pages/home-channels/runs";
import type { HomeMessage, HomeRun, HomeRunStep } from "../src/pages/home-channels/types";
import table from "../src/pages/home-channels/generated/strings.json";
import paneTable from "../src/pages/home-channels/generated/pane-strings.json";
import { createStrings } from "../src/pages/shared/i18n";

const strings = createStrings(table, ["en"]);
let dom: JSDOM;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let observerCallback: (entries: { isIntersecting: boolean }[]) => void;
let disconnected = 0;
function installDom() {
  dom = new JSDOM("<main id='root'></main>", { url: "https://cmux.test/", pretendToBeVisual: true });
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
    __cmuxPaneStrings: paneTable,
    IntersectionObserver: class {
      constructor(callback: typeof observerCallback) {
        observerCallback = callback;
      }
      observe() {}
      disconnect() {
        disconnected++;
      }
    },
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  disconnected = 0;
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  return container;
}
afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});
const run: HomeRun = {
  id: "run",
  conversation: "c",
  author: "chief",
  status: "done",
  startedAt: 1,
  updatedAt: 2,
  endedAt: 2,
  rev: 1,
  stepCount: 7,
  turn: "turn",
  answers: ["question"],
};
const step = (id: string, kind: HomeRunStep["kind"], seq: number): HomeRunStep => ({
  id,
  kind,
  seq,
  at: seq,
  rev: 1,
  text: id,
  links: [],
  attachments: [],
  ...(kind === "tool"
    ? { status: "done" as const, tool: { name: "Bash", input: { command: `echo ${id}` }, files: [] } }
    : {}),
});
const steps = [
  step("first", "tool", 1),
  step("second", "tool", 2),
  step("reason", "thought", 3),
  step("progress", "talk", 4),
  step("report", "note", 5),
  step("third", "tool", 6),
  step("fourth", "tool", 7),
];

test("the mapper keeps every tool, thought, talk and note in sequence beyond the card tail", () => {
  const blocks = runBlocks(run, steps);
  expect(blocks.map((block) => block.kind)).toEqual(["tools", "thought", "talk", "note", "tools"]);
  expect(
    blocks.flatMap((block) =>
      block.kind === "tools" ? block.row.items!.map((item) => item.tool!.id) : [block.step.id],
    ),
  ).toEqual(steps.map((step) => step.id));
});

test("the toggle defaults to Messages, persists per conversation, and restores on remount", async () => {
  const container = installDom();
  const render = (conversation: string) =>
    act(async () => root!.render(<PresentationToggle conversation={conversation} strings={strings} />));
  const button = (name: string) =>
    [...container.querySelectorAll("button")].find((button) => button.textContent === name)!;
  await render("c1");
  expect(button("Messages").getAttribute("aria-pressed")).toBe("true");
  await act(async () => button("Transcript").click());
  expect(readPresentation("c1")).toBe("transcript");
  await render("c2");
  expect(button("Messages").getAttribute("aria-pressed")).toBe("true");
  await act(async () => root!.unmount());
  root = createRoot(container);
  await render("c1");
  expect(button("Transcript").getAttribute("aria-pressed")).toBe("true");
  await act(async () => button("Messages").click());
  expect(readPresentation("c1")).toBe("messages");
  expect(readPresentation("c2")).toBe("messages");
});

test("inline steps load only while visible and the observer disconnects", async () => {
  installDom();
  const calls: string[] = [];
  const render = (rev: number) =>
    act(async () =>
      root!.render(
        <RunTranscript
          entry={{ run: { ...run, rev }, steps: [], complete: false }}
          strings={strings}
          agentNames={new Map()}
          onLoad={(run) => calls.push(run.id)}
        />,
      ),
    );
  await render(1);
  expect(calls).toEqual([]);
  await act(async () => observerCallback([{ isIntersecting: true }]));
  expect(calls).toEqual(["run"]);
  await act(async () => observerCallback([{ isIntersecting: false }]));
  await render(2);
  expect(calls).toEqual(["run"]);
  await act(async () => root!.unmount());
  root = undefined;
  expect(disconnected).toBe(1);
});

test("Transcript places all steps above the reply and Messages restores the run card below", async () => {
  const container = installDom();
  const book = new RunBook();
  const reply: HomeMessage = {
    id: "reply",
    conversation: "c",
    author: "chief",
    clientMessageId: "turn",
    seq: 2,
    createdAt: 2,
    retracted: false,
    parts: [{ type: "text", text: "Final reply", mentions: [] }],
    reactions: [],
  };
  book.setSteps(run, steps, true);
  const render = (presentation: "messages" | "transcript") =>
    act(async () =>
      root!.render(
        <RunsContext.Provider value={{ book, strings, presentation, onLoad: () => {}, onOpen: () => {} }}>
          <MessageRow
            message={reply}
            head={false}
            people={new Map()}
            strings={strings}
            timeFormat={new Intl.DateTimeFormat("en")}
            editing={false}
            onReact={() => {}}
          />
        </RunsContext.Provider>,
      ),
    );
  await render("transcript");
  const transcript = container.querySelector(".lg-run-transcript")!;
  expect(transcript.textContent).toContain("progress");
  expect(transcript.textContent).toContain("reason");
  expect(transcript.textContent).toContain("report");
  expect(transcript.querySelectorAll(".lg-run-block")).toHaveLength(5);
  expect(container.querySelector(".lg-run-toggle")).toBeNull();
  expect(container.textContent!.indexOf("progress")).toBeLessThan(container.textContent!.indexOf("Final reply"));
  await render("messages");
  expect(container.querySelector(".lg-run-transcript")).toBeNull();
  expect(container.querySelector(".lg-run-toggle")).not.toBeNull();
  expect(container.querySelector(".hc-msg-main")!.lastElementChild!.classList.contains("lg-run")).toBe(true);
});

test("a silent completed summary remains discoverable in Transcript before hydration", () => {
  const book = new RunBook();
  book.setRuns([{ ...run, turn: undefined }]);
  const question = { id: "question", conversation: "c" } as HomeMessage;
  expect(book.liveFor(question)).toHaveLength(0);
  expect(book.liveFor(question, true).map((entry) => entry.run.id)).toEqual(["run"]);
});
