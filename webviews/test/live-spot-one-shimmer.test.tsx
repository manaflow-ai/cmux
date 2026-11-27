// l10n-allow-file: test fixture prompts and tool titles, not shipped UI.
// The live spot (the running turn's "Thinking" line, Thinking.tsx) draws every status under ONE shimmer, and a turn the agent runs on its own
// (a helper finished, a message to send) has that line too. Leo, 2026-11-22: "these situations,
// there's no glimmer because... well shit i dont know. you sending messages or whatever aren't being
// accounted properly a la the "thinking" thing." and "the "waiting" also shouldnt be special cased as
// white. all in the "thinking" spot should glimmer like that". Scenarios ST-03 and ST-04.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SHIMMER_CLASS, Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { liveWait, THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { type LiveWait, subagentsLabel, waitingLabel } from "../src/agent-session/acpmux/conversation/liveWait";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";
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
  ["thinking", <Thinking key="k36" since={0} now={() => NOW} />, /^Thinking/],
  [
    "a named step",
    <Thinking key="k37" since={0} now={() => NOW} doing="Read App.tsx" doingAt={1_000} />,
    /^Read App\.tsx/,
  ],
  [
    "a running command",
    <Thinking key="k38" since={0} now={() => NOW} doing="bun test" doingShell doingAt={1_000} />,
    /bun test/,
  ],
  ["writing a command", <Thinking key="k39" since={0} now={() => NOW} doing="" doingShell draft />, /command/i],
  [
    "sending a message",
    <Thinking key="k42" since={0} now={() => NOW} doing="SendMessage" sendTo="tests" doingAt={1_000} />,
    /tests/,
  ],
  [
    "writing",
    <Thinking key="k45" since={0} now={() => NOW} liveState="writing" quietKey="reply:1" quietAt={NOW} />,
    /^Writing/,
  ],
  ["waiting on subagents", <Thinking key="k46" since={0} now={() => NOW} liveState="subagents" liveAgents={2} />, /2/],
  [
    "waiting (silent)",
    <Thinking key="k49" since={0} now={() => NOW} phaseAt={0} heardAt={0} heardKey="k" turnTotal />,
    /^Waiting/,
  ],
  [
    "compacting",
    <Thinking key="k52" since={0} now={() => NOW} liveState="compacting" doingAt={1_000} turnTotal />,
    /ompact/,
  ],
  [
    "waiting on one named subagent",
    <Thinking
      key="k55"
      since={0}
      now={() => NOW}
      liveState="subagents"
      liveAgents={1}
      liveAgentNames={["Explore auth"]}
    />,
    /^Waiting on subagent Explore auth/,
  ],
  [
    "waiting on two named subagents",
    <Thinking
      key="k60"
      since={0}
      now={() => NOW}
      liveState="subagents"
      liveAgents={2}
      liveAgentNames={["lint", "tests"]}
    />,
    /^Waiting on subagents lint and tests/,
  ],
  [
    "waiting on many subagents",
    <Thinking
      key="k65"
      since={0}
      now={() => NOW}
      liveState="subagents"
      liveAgents={4}
      liveAgentNames={["lint", "tests"]}
    />,
    /^Waiting on subagent lint and 3 more/,
  ],
  ...(
    [
      [{ kind: "step", step: "Ran bun test" }, /^Waiting on the model after: Ran bun test/],
      [{ kind: "prompt" }, /^Waiting on the model's first reply/],
      [{ kind: "message", from: "picker" }, /^Waiting on the model after picker's message/],
      [{ kind: "queued" }, /^Waiting on the model to read your queued message/],
      [{ kind: "next" }, /^Waiting on the model's next step/],
      [undefined, /^Waiting on the model's next step/],
    ] as [LiveWait | undefined, RegExp][]
  ).map(([liveWait, label]): [string, ReactNode, RegExp] => [
    `waiting (silent, ${liveWait?.kind ?? "unknown"})`,
    <Thinking
      key={liveWait?.kind ?? "unknown"}
      since={0}
      now={() => NOW}
      phaseAt={0}
      heardAt={0}
      heardKey="k"
      liveWait={liveWait}
      turnTotal
    />,
    label,
  ]),
];

// Never a bare "Waiting": every silent line names what it waits on (Leo, 2026-11-22: "everything that
// goes in there write more detailed things than just waiting").
for (const [name, node] of statuses)
  test(`the live line's "${name}" status says more than a bare "Waiting"`, () => {
    expect(words(renderToStaticMarkup(node))).not.toMatch(/^Waiting(\s+\d|$)/);
  });

// The same look as "Thinking" for every status: the one shimmer's structure (its base words, its
// band and lit copy), so no status draws its words plainly in another tone.
const thinkingLook = renderToStaticMarkup(<Thinking since={0} now={() => NOW} />);
for (const [name, node] of statuses)
  test(`the live line's "${name}" status draws the shimmer's layers as "Thinking" does`, () => {
    const html = renderToStaticMarkup(node);
    for (const layer of ["cv-shimmer__row", "cv-shimmer__base", "cv-shimmer__band"]) {
      expect(thinkingLook).toContain(layer);
      expect(html).toContain(layer);
    }
  });

test("subagentsLabel and waitingLabel name what the line waits on", () => {
  const t = translatorFor("en");
  expect(subagentsLabel(t, 2)).toBe("Waiting on 2 subagents");
  expect(subagentsLabel(t, 1, ["a"])).toBe("Waiting on subagent a");
  expect(subagentsLabel(t, 2, ["a"])).toBe("Waiting on subagent a and 1 more");
  expect(subagentsLabel(t, 2, ["a", "b"])).toBe("Waiting on subagents a and b");
  expect(subagentsLabel(t, 5, ["a", "b", "c"])).toBe("Waiting on subagent a and 4 more");
  expect(waitingLabel(t, { kind: "step", step: "Read App.tsx" })).toBe("Waiting on the model after: Read App.tsx");
});

// The turn's rows say what a silent line waits on (turns.ts `liveWait`).
const tool = (status: string, extra: Record<string, unknown> = {}): AcpmuxRow =>
  ({
    id: "act1",
    version: 1,
    at: 2_000,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "bun test",
        tool: { id: "c1", title: "bun test", kind: "execute", command: "bun test", status, startedAt: 2_000, ...extra },
      },
    ],
  }) as AcpmuxRow;
const asked: AcpmuxRow = { id: "u1", version: 1, at: 1_000, kind: "user", text: "Run the tests" };

test("after a call returns, the line waits on the model after that call", () => {
  const ran = tool("completed", { endedAt: 3_000 });
  expect(liveWait([asked, ran], ran)).toEqual({ kind: "step", step: "Ran tests with bun" });
});

test("after a thought or a reply, the line waits on the model's next step", () => {
  const reply: AcpmuxRow = { id: "a1", version: 1, at: 2_000, kind: "assistant", text: "Done." };
  expect(liveWait([asked, reply], reply)).toEqual({ kind: "next" });
  const thought = {
    id: "t1",
    version: 1,
    at: 2_000,
    kind: "activity",
    items: [{ kind: "thought", text: "Hmm", startedAt: 2_000, endedAt: 2_500 }],
  } as AcpmuxRow;
  expect(liveWait([asked, thought], thought)).toEqual({ kind: "next" });
});

test("another agent's message, the person's queued message and a bare prompt each say so", () => {
  const message = {
    id: "u2",
    version: 1,
    at: 2_000,
    kind: "user",
    text: "done",
    incoming: { kind: "message", message: { name: "picker" } },
  } as AcpmuxRow;
  expect(liveWait([asked, message], message)).toEqual({ kind: "message", from: "picker" });
  const steer: AcpmuxRow = { id: "u3", version: 1, at: 2_500, kind: "user", text: "also lint", steer: "waiting" };
  const ran = tool("completed", { endedAt: 3_000 });
  expect(liveWait([asked, steer, ran], ran)).toEqual({ kind: "queued" });
  expect(liveWait([asked], asked)).toEqual({ kind: "prompt" });
});

test("a silent live turn's line carries what it waits on, and a subagent wait carries the names", () => {
  const ran = tool("completed", { endedAt: 3_000 });
  const view = turnView([asked, ran], new Set(), { now: 60_000, working: true });
  const line = view.at(-1)!;
  expect(line.kind).toBe(THINKING);
  expect(line.liveWait).toEqual({ kind: "step", step: "Ran tests with bun" });
});

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
  // Retrying for a minute, past the quiet bound a retry waits before the line says so.
  const html = renderToStaticMarkup(
    <Thinking since={0} now={() => NOW} retry={{ attempt: 2, maxRetries: 10 }} retryAt={NOW - 60_000} />,
  );
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

test("the Working-for line's wait on the person shimmers too, never plain white words", () => {
  const row: AcpmuxRow = { id: "working-p", version: 1, at: 0, kind: "working", below: true };
  const html = renderToStaticMarkup(
    <WaitingOnContext value="permission">
      <WorkingFor row={row} now={() => NOW} />
    </WaitingOnContext>,
  );
  expect(html).toContain(`cv-thinking ${SHIMMER_CLASS}`);
  expect(html).toContain("cv-shimmer__band");
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
