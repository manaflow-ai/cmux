// l10n-allow-file: test fixture prompts and tool titles, not shipped UI.
// The live spot (the running turn's "Thinking" line, Thinking.tsx, and the activity line under a todo
// list, ActivityLine.tsx) draws every status under ONE shimmer, and a turn the agent runs on its own
// (a helper finished, a message to send) has that line too. Leo, 2026-11-22: "these situations,
// there's no glimmer because... well shit i dont know. you sending messages or whatever aren't being
// accounted properly a la the "thinking" thing." and "the "waiting" also shouldnt be special cased as
// white. all in the "thinking" spot should glimmer like that". Scenarios ST-03 and ST-04.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ActivityLine } from "../src/agent-session/acpmux/conversation/ActivityLine";
import { BACKGROUND_TURN } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { SHIMMER_CLASS, Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { type WaitingOn, WaitingOnContext } from "../src/agent-session/acpmux/conversation/waitingOn";

afterEach(() => {
  delete globalThis.cmuxExperiments;
});

const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x27;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
const shimmers = (html: string) => html.includes(`cv-thinking ${SHIMMER_CLASS}`);
const NOW = 60_000;

// Every label the Thinking line can show, by the props that make it.
const statuses: [string, ReactNode, RegExp][] = [
  ["thinking", <Thinking since={0} now={() => NOW} />, /^Thinking/],
  ["a named step", <Thinking since={0} now={() => NOW} doing="Read App.tsx" doingAt={1_000} />, /^Read App\.tsx/],
  ["a running command", <Thinking since={0} now={() => NOW} doing="bun test" doingShell doingAt={1_000} />, /bun test/],
  ["writing a command", <Thinking since={0} now={() => NOW} doing="" doingShell draft />, /command/i],
  [
    "sending a message",
    <Thinking since={0} now={() => NOW} doing="SendMessage" sendTo="tests" doingAt={1_000} />,
    /tests/,
  ],
  ["writing", <Thinking since={0} now={() => NOW} liveState="writing" quietKey="reply:1" quietAt={NOW} />, /^Writing/],
  ["waiting on subagents", <Thinking since={0} now={() => NOW} liveState="subagents" liveAgents={2} />, /2/],
  [
    "waiting (silent)",
    <Thinking since={0} now={() => NOW} phaseAt={0} heardAt={0} heardKey="k" turnTotal />,
    /^Waiting/,
  ],
  ["compacting", <Thinking since={0} now={() => NOW} liveState="compacting" doingAt={1_000} turnTotal />, /ompact/],
];

for (const [name, node, label] of statuses)
  test(`the live line's "${name}" status draws the one shared shimmer`, () => {
    const html = renderToStaticMarkup(node);
    expect(words(html)).toMatch(label);
    expect(shimmers(html)).toBe(true);
    // No colour of its own: never an inline colour, never the plain (unshimmered) words.
    expect(html).not.toContain("style=");
  });

for (const arm of ["own", "turn", "calm"])
  test(`a compaction shimmers in the "${arm}" look too`, () => {
    globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "compacting-line": arm };
    const html = renderToStaticMarkup(
      <Thinking since={0} now={() => NOW} liveState="compacting" doingAt={1_000} turnTotal />,
    );
    expect(shimmers(html)).toBe(true);
  });

test("a retry shimmers as Thinking does", () => {
  const html = renderToStaticMarkup(<Thinking since={0} now={() => NOW} retry={{ attempt: 2, maxRetries: 10 }} />);
  expect(html).toContain(`cv-thinking ${SHIMMER_CLASS} cv-retrying`);
  expect(html).toContain("cv-shimmer__band");
});

for (const waiting of ["trust", "trustRemote", "permission", "secret"] as WaitingOn[])
  test(`waiting on the person (${waiting}) keeps its pill and shimmers its words`, () => {
    const html = renderToStaticMarkup(
      <WaitingOnContext value={waiting}>
        <Thinking since={0} now={() => NOW} />
      </WaitingOnContext>,
    );
    expect(html).toContain(`cv-thinking ${SHIMMER_CLASS} cv-waiting`);
    expect(html).toMatch(/cv-waiting__pill"><span class="cv-shimmer__row"><span class="cv-shimmer__base">/);
  });

test("the activity line shimmers its step, its thinking verb, its wait and a message going out", () => {
  const base: AcpmuxRow = { id: "activityLine-p", version: 1, at: 0, kind: "activityLine", below: true };
  const step = renderToStaticMarkup(<ActivityLine row={{ ...base, text: "Edit gen.py" }} now={() => NOW} />);
  expect(step).toContain(`cv-activity__label cv-thinking ${SHIMMER_CLASS}`);
  const sending = renderToStaticMarkup(
    <ActivityLine row={{ ...base, text: "SendMessage", doingSendTo: "tests" }} now={() => NOW} />,
  );
  expect(sending).toContain("cv-activity-row is-live");
  expect(sending).toContain("cv-row-shimmer");
  const waiting = renderToStaticMarkup(
    <WaitingOnContext value="permission">
      <ActivityLine row={{ ...base, text: "Edit gen.py" }} now={() => NOW} />
    </WaitingOnContext>,
  );
  expect(waiting).toContain(`cv-activity__label cv-thinking ${SHIMMER_CLASS}`);
  expect(waiting).not.toContain("cv-waiting");
});

test("no status in the live spot has a colour of its own: the shimmer's tone is the only one", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  );
  const rule = (selector: string) => {
    const at = css.indexOf(`\n${selector} {`);
    expect(at).toBeGreaterThanOrEqual(0);
    return css.slice(at, css.indexOf("}", at));
  };
  expect(rule(".cv-retrying")).not.toContain("color:");
  expect(rule(".cv-thinking.cv-waiting")).not.toContain("color:");
});

// A turn the agent runs on its own after its prompt's turn ended (acpmux `background_turn`): acpmux
// lists the chat idle, so the turn is not `working`, yet its sends and waits are work.
const prompt: AcpmuxRow = { id: "p1", version: 1, at: 1_000, kind: "user", text: "Coordinate the lanes" };
const reply: AcpmuxRow = { id: "r1", version: 1, at: 2_000, kind: "assistant", text: "On it." };
const summary: AcpmuxRow = { id: "s1", version: 1, at: 3_000, kind: "turnSummary", status: "completed" } as AcpmuxRow;
const background = (running: boolean): AcpmuxRow =>
  ({
    id: "backgroundTurn-bg1",
    version: running ? 1 : 2,
    at: 10_000,
    kind: BACKGROUND_TURN,
    background: { id: "bg1", trigger: "task", running, ...(running ? {} : { quiet: false }) },
  }) as AcpmuxRow;
const send = (status: string): AcpmuxRow =>
  ({
    id: "a1",
    version: 1,
    at: 11_000,
    kind: "activity",
    inBackground: "backgroundTurn-bg1",
    items: [
      {
        kind: "tool",
        text: "SendMessage",
        tool: {
          id: "m1",
          title: "SendMessage",
          kind: "other",
          status,
          startedAt: 11_000,
          ...(status === "completed" && { endedAt: 11_500 }),
          inputSummary: JSON.stringify({ to: "picker", message: "Keep going." }),
        },
      },
    ],
  }) as AcpmuxRow;

test("a turn whose newest activity is a send still going is live: the line names the recipient", () => {
  const view = turnView([prompt, reply, summary, background(true), send("in_progress")], new Set(), {
    now: 12_000,
    working: false,
  });
  const line = view.at(-1)!;
  expect(line.kind).toBe(THINKING);
  expect(line.doingSendTo).toBe("picker");
});

test("a turn whose newest activity is a finished send is still live: the line reads Thinking", () => {
  const view = turnView([prompt, reply, summary, background(true), send("completed")], new Set(), {
    now: 12_000,
    working: false,
  });
  const line = view.at(-1)!;
  expect(line.kind).toBe(THINKING);
  expect(line.doing).toBeUndefined();
  expect(line.turnTotal).toBe(true);
});

test("a helper's finish that starts a turn of its own is live before its first step", () => {
  const view = turnView([prompt, reply, summary, background(true)], new Set(), { now: 12_000, working: false });
  expect(view.at(-1)?.kind).toBe(THINKING);
});

test("once that turn ends, no live line is left", () => {
  const view = turnView([prompt, reply, summary, background(false), send("completed")], new Set(), {
    now: 12_000,
    working: false,
  });
  expect(view.some((row) => row.kind === THINKING)).toBe(false);
});
