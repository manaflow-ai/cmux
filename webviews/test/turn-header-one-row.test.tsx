// l10n-allow-file: test fixture prompts, messages and commands, not shipped UI.
// A turn's header is one row from the turn's start to its end (transcript motion model: a row keeps
// one id, kind and element from birth to leaving; its state is a phase). The running "Working for"
// and the ended "Worked for" are the same row in two phases, so the turn's end swaps its words and
// nothing leaves or comes in. Its clock has one start and one formula in both phases, the summary
// line of a run of messages never reorders its phrases as the run grows, and a sender's machine on a
// received line never comes in after the line is drawn.
//
// Leo, 2026-11-17, on a turn another agent's message started: "the jostles and shifts and spacing
// are still bad here".
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { WORKED, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { foldMessageRuns, messageRunSummary } from "../src/agent-session/acpmux/conversation/messageRuns";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  Range: dom.window.Range,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const tool = (id: string, title: string, kind: string, fields: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id, title, kind, status: "completed", ...fields },
});
const run = (id: string, command: string) => tool(id, command, "execute", { command, output: "ok\n" });
const send = (id: string, to: string, message: string) =>
  tool(id, "SendMessage", "other", { inputSummary: JSON.stringify({ to, message }) });
const call = (id: string, at: number, items: AcpmuxActivity[]) =>
  row(id, "activity", at, { items, toolCount: items.length });
const commentary = (id: string, at: number, text: string) =>
  row(id, "assistant", at, { text, assistantPhase: "commentary" } as Partial<AcpmuxRow>);
const finalAnswer = (id: string, at: number, text: string) =>
  row(id, "assistant", at, { text, assistantPhase: "final_answer" } as Partial<AcpmuxRow>);
const summary = (at: number, durationMs: number) =>
  row("summary", "turnSummary", at, { status: "completed", durationMs, toolCount: 1 });
const received = (id: string, at: number, name: string, text: string, continues = true) =>
  row(id, "user", at, {
    text,
    ...(continues && { continues: true }),
    incoming: { kind: "message", message: { name, sessionId: `s-${name}`, text, raw: text } },
  } as Partial<AcpmuxRow>);

const shown = (rows: readonly AcpmuxRow[]) => rows.filter((each) => each.kind !== "date");
const live = (rows: AcpmuxRow[], now = 60_000) =>
  shown(turnView(rows, new Set(), { now, agentFamily: "codex", working: true }));
const ended = (rows: AcpmuxRow[]) => shown(turnView(rows, new Set(), { now: 60_000, agentFamily: "codex" }));
/// The turn's header, running or ended: the one row its end draws "Worked for" in.
const header = (rows: readonly AcpmuxRow[], promptId: string) =>
  rows.find((each) => each.id === `${WORKED}-${promptId}`);
const phaseOf = (each: AcpmuxRow | undefined) => (each as { turnPhase?: string } | undefined)?.turnPhase ?? "ended";

// The person's turn: a prompt, a note, a command, another note; then the answer and its end.
const personTurn = [
  row("u", "user", 0, { text: "Build the page" }),
  commentary("plan", 1_000, "I'll check the project first."),
  call("c1", 2_000, [run("c1-run", "ls")]),
  commentary("note", 3_000, "Now the layout."),
];
const personEnded = [...personTurn, finalAnswer("answer", 4_000, "The page is built."), summary(5_000, 5_000)];

test("the person's turn: the header over its work is the row its end draws, one id and kind, phase running then ended", () => {
  const running = header(live(personTurn), "u");
  const done = header(ended(personEnded), "u");
  expect(running).toBeDefined();
  expect(done).toBeDefined();
  expect(running!.kind).toBe(WORKED);
  expect(done!.kind).toBe(WORKED);
  expect(phaseOf(running)).toBe("running");
  expect(phaseOf(done)).toBe("ended");
  // In the same place: right under the prompt, in both phases.
  expect(live(personTurn).findIndex((each) => each.id === running!.id)).toBe(1);
  expect(ended(personEnded).findIndex((each) => each.id === done!.id)).toBe(1);
  // One id across the turn's end.
  expect(running!.id).toBe(done!.id);
});

// Another agent's message started the turn: its header stands from the turn's first frame (decided
// at the start) and is the same row in every frame to the end.
const prompt = received("msg", 0, "ci-watch", "CI finished: 41 checks green, 2 red.", false);
const agentFrames: AcpmuxRow[][] = [
  [prompt],
  [prompt, call("a-send", 1_000, [send("a-send-1", "ci-watch", "Rerun webviews-browser.")])],
  [
    prompt,
    call("a-send", 1_000, [send("a-send-1", "ci-watch", "Rerun webviews-browser.")]),
    received("a-recv", 2_000, "ci-watch", "Queued the rerun."),
    call("a-run", 3_000, [run("a-run-1", "gh pr view 45222")]),
  ],
];
const agentEnded = [...agentFrames[2]!, summary(4_000, 4_000)];

test("a turn another agent's message started: one header row, in one place, from the first frame to the end", () => {
  const frames = [...agentFrames.map((rows) => live(rows)), ended(agentEnded)];
  for (const [index, rows] of frames.entries()) {
    const found = header(rows, "msg");
    expect({ frame: index, id: found?.id, kind: found?.kind, at: found ? rows.indexOf(found) : -1 }).toEqual({
      frame: index,
      id: `${WORKED}-msg`,
      kind: WORKED,
      at: 0,
    });
    expect(phaseOf(found)).toBe(index < agentFrames.length ? "running" : "ended");
  }
});

test("the transcript keeps the header's element from the running turn to the ended one", async () => {
  const Row = ({ row: item }: { row: AcpmuxRow }) => <div>{item.id}</div>;
  const running = live(personTurn);
  const done = ended(personEnded);
  const registry = Object.fromEntries([...running, ...done].map((item) => [item.kind, Row])) as never;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const draw = async (rows: AcpmuxRow[]) => {
    await act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId="turn-header-one-row"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    return host.querySelector<HTMLElement>(`[data-row-id="${WORKED}-u"]`);
  };
  try {
    const before = await draw(running);
    const after = await draw(done);
    expect(before).not.toBeNull();
    expect(after).toBe(before);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

// The clock: one start and one formula while the turn runs and once it ended. A message another
// agent sent after the agent had replied started the turn's current stretch (`continuationStart`):
// the running clock counts from it, and so does the ended "Worked for".
const continued = [
  row("cu", "user", 0, { text: "Watch the nightly" }),
  commentary("cu-ok", 1_000, "Watching."),
  received("cu-recv", 20_000, "ci-watch", "Nightly is red on webviews-browser."),
  call("cu-run", 21_000, [run("cu-run-1", "gh run view 1873402219")]),
];
const continuedAnswered = [...continued, finalAnswer("cu-answer", 30_000, "Rerun queued.")];
const continuedEnded = [...continuedAnswered, summary(31_000, 31_000)];

test("the header's clock has one start and one formula, running and ended, and never runs backwards", () => {
  const running = header(live(continued, 25_000), "cu");
  expect(running).toBeDefined();
  // Running: it ticks from the stretch's start.
  expect(running!.at).toBe(20_000);
  expect(running!.durationMs).toBeUndefined();
  // The answer has come: the turn folds under its line before its end, which reads from the same
  // start to the answer.
  const answered = header(live(continuedAnswered, 32_000), "cu");
  expect(answered!.durationMs).toBe(30_000 - 20_000);
  // Ended: the same start, the same end.
  const done = header(ended(continuedEnded), "cu");
  expect(done!.durationMs).toBe(30_000 - 20_000);
  expect(answered!.durationMs).toBe(done!.durationMs);
});

test("the header's clock never decreases, tick by tick, across the answer and the turn's end", () => {
  // What the header reads at `now`: its fixed duration once set, else the time since its start.
  const reads = (rows: readonly AcpmuxRow[], now: number) => {
    const found = header(rows, "cu")!;
    expect(found).toBeDefined();
    return found.durationMs ?? now - found.at;
  };
  const frames: number[] = [];
  for (let now = 22_000; now < 30_000; now += 500) frames.push(reads(live(continued, now), now));
  for (let now = 30_000; now <= 31_000; now += 250) frames.push(reads(live(continuedAnswered, now), now));
  frames.push(reads(ended(continuedEnded), 60_000));
  for (let index = 1; index < frames.length; index += 1)
    expect({ index, decreased: frames[index]! < frames[index - 1]! }).toEqual({ index, decreased: false });
  // And one id the whole way.
  expect(header(live(continued, 22_000), "cu")!.id).toBe(header(ended(continuedEnded), "cu")!.id);
});

test("a run's summary line keeps its phrases in the order they came as the run grows", () => {
  // A command first, then a message sent, then one received: each phrase keeps its place as the next
  // comes in, and the ended line reads in that same order.
  const steps = [
    call("r1", 1_000, [run("r1-run", "gh pr view 45222")]),
    call("r2", 2_000, [send("r2-send", "ci-watch", "Rerun webviews-browser.")]),
    received("r3", 3_000, "ci-watch", "Queued."),
    call("r4", 4_000, [run("r4-run", "gh run watch 1873402219")]),
  ].map((each) => (each.kind === "activity" ? { ...each, foldRun: true } : each));
  const lines: string[] = [];
  for (let count = 2; count <= steps.length; count += 1) {
    const line = foldMessageRuns(steps.slice(0, count), new Set()).find((each) => each.messageRun);
    if (line) lines.push(messageRunSummary(translate, line.messageRun!));
  }
  expect(lines).toEqual([
    "Ran a command, sent a message",
    "Ran a command, sent a message, received a message",
    "Ran 2 commands, sent a message, received a message",
  ]);
});

test("a received line's sender machine never comes in after the line is drawn", async () => {
  const store = new SubsessionStore();
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const text = "Rebased; ready for review.";
  try {
    await act(async () =>
      root.render(
        <SubsessionContext.Provider value={{ store, open: () => undefined }}>
          <IncomingMessageLine
            id="row-1"
            message={{ name: "chief-ui", sessionId: "mux-chief-ui", text, raw: text }}
            onOpen={() => undefined}
          />
        </SubsessionContext.Provider>,
      ),
    );
    const slots = () =>
      [...host.querySelectorAll(".cv-received__sender > *")].map((each) => each.className.split(" ")[0]);
    const before = slots();
    // The chat list names the sender's machine only after the line is drawn.
    await act(async () =>
      store.set([
        {
          sessionId: "mux-chief-ui",
          name: "huge-blue/chief-ui",
          displayTitle: "chief-ui",
          peer: "huge-blue",
          pendingPermissions: 0,
        } as AcpmuxSessionEntry,
      ]),
    );
    expect(slots()).toEqual(before);
  } finally {
    await act(async () => root.unmount());
  }
});
