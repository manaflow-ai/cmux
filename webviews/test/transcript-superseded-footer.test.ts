// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A stretch of a turn the person came in on counts as ended: the agent's text before a steer that
// landed (a message sent into the running turn, or one sent now), and a turn with no summary that his
// next prompt opened over, get the end-of-turn footer with Copy, as Claude Code desktop draws them
// (Leo, 2026-11-03: "i also think a lot of these should've been counted as "ended"-ish turns that allow
// me to copy/paste your stuff / cuz look claude code lets that happen if the user comes in").
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import { SUPERSEDED, footerLabel, isEmptyFooter, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { TurnFooter } from "../src/agent-session/acpmux/conversation/TurnRows";
import { waterfall } from "../src/agent-session/acpmux/conversation/waterfallSpans";

const START = Date.UTC(2026, 10, 3, 20, 0, 0);
let at = START;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 10_000),
  ...extra,
});
const bash = (id: string) =>
  row(`a-${id}`, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }],
  });

const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);
const footers = (rows: readonly AcpmuxRow[]) => rows.filter((each) => each.kind === "turnSummary");

const running = (steer: AcpmuxRow["steer"], extra: Partial<AcpmuxRow> = {}) => [
  row("u", "user", { text: "Plan the transfer work" }),
  bash("b0"),
  row("r1", "assistant", { text: "All three are contained Rust changes. Want me to start with the seed?", ...extra }),
  bash("b1"),
  row("s1", "user", { text: "ofc", steer }),
  bash("b2"),
];

for (const family of ["claude", "codex"])
  test(`${family}: a running turn's stretch before a landed steer ends on a footer with Copy`, () => {
    const view = turnView(running("landed"), new Set(), {
      working: true,
      agentFamily: family,
      now: START + 200_000,
    });
    const list = ids(view);
    const footer = view.find((each) => each.id === `${SUPERSEDED}-s1`);
    expect(footer).toBeDefined();
    expect(footer!.kind).toBe("turnSummary");
    expect(footer!.superseded).toBe(true);
    expect(footer!.text).toContain("Want me to start with the seed?");
    expect(footer!.answerId).toBe("r1");
    expect(footer!.turnCopy?.some((part) => "text" in part && part.text.includes("contained Rust"))).toBe(true);
    // Right over the steer, after the work the stretch ended on.
    expect(list.indexOf(`${SUPERSEDED}-s1`)).toBe(list.indexOf("s1") - 1);
    // Its time is the stretch's; its tooltip says how long the stretch worked, from the prompt to the
    // steer, as a turn's own footer does (Leo, 2026-11-08: "I wasn't able to hover over your
    // timestamp to see, like, this was in and out or whatever ... I steered it?").
    // Each fixture row comes 10 s after the last: the steer is four rows after the prompt.
    expect(footer!.durationMs).toBe(40_000);
    expect(footerLabel(translate, footer!)).toBe(translate("turn.worked", { time: "40s" }));
  });

test("a stretch's Timeline starts at its prompt, with each call at its real offset", () => {
  // The prompt at 0 s, a command from 10 s to 30 s, the reply at 30 s, the steer at 40 s: the stretch
  // worked 40 s, and its Timeline's axis runs from the prompt to the steer, so the command sits at
  // 10-30 s, never shifted by the 10 s between the reply and the steer.
  const at0 = START + 1_000_000;
  const rows: AcpmuxRow[] = [
    { id: "u", kind: "user", version: 1, at: at0, text: "Plan the transfer work" },
    {
      id: "a-b0",
      kind: "activity",
      version: 1,
      at: at0 + 10_000,
      items: [
        {
          kind: "tool",
          text: "",
          tool: {
            id: "b0",
            title: "Run b0",
            kind: "execute",
            status: "completed",
            startedAt: at0 + 10_000,
            endedAt: at0 + 30_000,
          },
        },
      ],
    },
    { id: "r1", kind: "assistant", version: 1, at: at0 + 30_000, text: "All three are contained Rust changes." },
    { id: "s1", kind: "user", version: 1, at: at0 + 40_000, text: "ofc", steer: "landed" },
  ];
  const view = turnView(rows, new Set(), { working: true, agentFamily: "claude", now: at0 + 60_000 });
  const footer = view.find((each) => each.id === `${SUPERSEDED}-s1`)!;
  expect(footer.durationMs).toBe(40_000);
  // Its time is still its reply's.
  expect(footer.at).toBe(at0 + 30_000);
  const chart = waterfall(footer, footer.turnWork!);
  expect(chart.start).toBe(at0);
  expect(chart.total).toBe(40_000);
  expect(chart.spans.map(({ from, to }) => [from, to])).toEqual([[10_000, 30_000]]);
});

test("an ended turn keeps its own footer and adds one over the steer", () => {
  const rows = [
    ...running("landed"),
    row("r2", "assistant", { text: "Seed is hooked in." }),
    row("sum", "turnSummary", { status: "completed" }),
  ];
  for (const family of ["claude", "codex"]) {
    const view = turnView(rows, new Set(), { agentFamily: family, now: START + 400_000 });
    const list = ids(footers(view));
    expect(list).toEqual([`${SUPERSEDED}-s1`, "sum"]);
    // The turn's own footer copies the whole turn as before.
    expect(view.find((each) => each.id === "sum")!.text).toBe("Seed is hooked in.");
  }
});

test("a Send now (the prompt continues the turn it ended) counts too", () => {
  const rows = [
    row("u", "user", { text: "Plan the transfer work" }),
    row("r1", "assistant", { text: "Here is the plan." }),
    bash("b1"),
    row("stop", "turnSummary", { status: "cancelled", continued: true }),
    row("s1", "user", { text: "do it now", continues: true }),
    bash("b2"),
  ];
  const view = turnView(rows, new Set(), { working: true, agentFamily: "claude", now: START + 1e6 });
  expect(ids(footers(view))).toEqual([`${SUPERSEDED}-s1`]);
});

test("no footer for a steer the agent has not read, a reply still streaming, or work alone", () => {
  const options = { working: true, agentFamily: "claude", now: START + 1e6 };
  expect(footers(turnView(running("waiting"), new Set(), options))).toEqual([]);
  expect(footers(turnView(running("landed", { streaming: true }), new Set(), options))).toEqual([]);
  const workOnly = [
    row("u", "user", { text: "Run it" }),
    bash("w0"),
    row("s1", "user", { text: "and this", steer: "landed" }),
  ];
  expect(footers(turnView(workOnly, new Set(), options))).toEqual([]);
});

test("another agent's message into the turn is not the person coming in", () => {
  const rows = [
    row("u", "user", { text: "Plan the transfer work" }),
    row("r1", "assistant", { text: "Here is the plan." }),
    row("m1", "user", {
      text: "lane report",
      steer: "landed",
      incoming: {
        kind: "message",
        message: { name: "lane", sessionId: "lane-1", text: "lane report", raw: "lane report" },
      } as AcpmuxRow["incoming"],
    }),
    bash("b2"),
  ];
  const view = turnView(rows, new Set(), { working: true, agentFamily: "claude", now: START + 1e6 });
  expect(footers(view)).toEqual([]);
});

test("a turn with no summary that the person's next prompt opened over ends on a footer", () => {
  const rows = [
    row("u", "user", { text: "Plan the transfer work" }),
    row("r1", "assistant", { text: "All three are contained Rust changes." }),
    bash("b1"),
    row("u2", "user", { text: "ofc" }),
    row("r2", "assistant", { text: "On it." }),
    row("sum2", "turnSummary", { status: "completed" }),
  ];
  const view = turnView(rows, new Set(), { agentFamily: "claude", now: START + 1e6 });
  const list = ids(view);
  const footer = view.find((each) => each.id.startsWith(`${SUPERSEDED}-`));
  expect(footer?.text).toBe("All three are contained Rust changes.");
  expect(list.indexOf(footer!.id)).toBe(list.indexOf("u2") - 1);
  // Not when another agent's message opened the next turn: this one may still go on.
  const incoming = rows.map((each) =>
    each.id === "u2"
      ? {
          ...each,
          incoming: {
            kind: "message",
            message: { name: "lane", sessionId: "lane-1", text: "lane report", raw: "lane report" },
          } as AcpmuxRow["incoming"],
        }
      : each,
  );
  expect(
    turnView(incoming, new Set(), { agentFamily: "claude", now: START + 1e6 }).some((each) => each.superseded),
  ).toBe(false);
});

// Leo, 2026-11-12: "COPY SHOULDN'T DO ANYTHING IF ALL THAT CHANGED WAS I SENT A MESSAGE THERE'S NO
// POINT HAVING THE SECOND BUTTON ROW AFTER MY MESSAGE". acpmux ends a Claude turn the person's message
// came into and carries the message to the next turn, so the turn's own footer came right under his
// bubble, copying only what the row over his message already copies. A footer draws its row only for
// what the agent said after his message.
const markup = (footer: AcpmuxRow) => renderToStaticMarkup(createElement(TurnFooter, { row: footer }));
const COPY = 'aria-label="Copy"';

const steeredThenEnded = (after: AcpmuxRow[] = []) => [
  row("u", "user", { text: "Plan the transfer work" }),
  row("r1", "assistant", { text: "Got it. I've dropped the plan." }),
  row("s1", "user", { text: "THIS IS THE THING", steer: "landed" }),
  ...after,
  row("sum", "turnSummary", { status: "completed", durationMs: 30_000 }),
];

for (const family of ["claude", "codex"])
  test(`${family}: a turn that ended right after the person's message draws one row, over his message`, () => {
    for (const working of [true, false]) {
      const view = turnView(steeredThenEnded(), new Set(), { working, agentFamily: family, now: START + 1e6 });
      // One row that shows: the one over his message, with its Copy.
      const shown = footers(view).filter((each) => !isEmptyFooter(each));
      expect(ids(shown)).toEqual([`${SUPERSEDED}-s1`]);
      expect(markup(shown[0]!)).toContain(COPY);
      // The footer under his message, where drawn, has nothing new: no Copy, no Read aloud, no line.
      const under = view.find((each) => each.id === "sum");
      if (!working) expect(under).toBeDefined();
      if (under) {
        expect(under.text).toBeUndefined();
        expect(under.turnCopy).toBeUndefined();
        expect(markup(under)).toContain("cv-turn-actions--empty");
        expect(markup(under)).not.toContain(COPY);
      }
    }
  });

test("two messages in a row, then the turn ended: still no row under them", () => {
  const second = row("s2", "user", { text: "AND THIS", steer: "landed" });
  const view = turnView(steeredThenEnded([second]), new Set(), { agentFamily: "claude", now: START + 1e6 });
  expect(ids(footers(view).filter((each) => !isEmptyFooter(each)))).toEqual([`${SUPERSEDED}-s1`]);
});

test("work alone after the person's message adds no row either", () => {
  const view = turnView(steeredThenEnded([bash("b9")]), new Set(), { agentFamily: "claude", now: START + 1e6 });
  expect(isEmptyFooter(view.find((each) => each.id === "sum")!)).toBe(true);
});

test("a reply after the person's message keeps the turn's row and its Copy", () => {
  const reply = row("r2", "assistant", { text: "Seed is hooked in." });
  const view = turnView(steeredThenEnded([reply]), new Set(), { agentFamily: "claude", now: START + 1e6 });
  const under = view.find((each) => each.id === "sum")!;
  expect(under.text).toBe("Seed is hooked in.");
  expect(isEmptyFooter(under)).toBe(false);
  expect(markup(under)).toContain(COPY);
});

test("send a message: no assistant action row until assistant content arrives", () => {
  const options = { agentFamily: "claude", now: START + 1e6 };
  // A new prompt sent after a finished turn: only the finished turn's row.
  const done = [
    row("p1", "user", { text: "First" }),
    row("a1", "assistant", { text: "First answer." }),
    row("e1", "turnSummary", { status: "completed", durationMs: 5_000 }),
  ];
  const sent = [...done, row("p2", "user", { text: "Second", pending: true })];
  expect(ids(footers(turnView(sent, new Set(), { ...options, working: true })))).toEqual(["e1"]);
  // The prompt went and its turn runs with nothing said yet: still no row for it.
  const opened = [...done, row("p2", "user", { text: "Second" })];
  expect(ids(footers(turnView(opened, new Set(), { ...options, working: true })))).toEqual(["e1"]);
  // A message into a running turn the agent then ended (acpmux carries it to the next turn): the
  // turn's own footer draws nothing while the carried turn runs with nothing said.
  const carried = steeredThenEnded();
  const live = turnView(carried, new Set(), { ...options, working: true });
  expect(
    footers(live)
      .filter((each) => !isEmptyFooter(each))
      .map((each) => each.id),
  ).toEqual([`${SUPERSEDED}-s1`]);
  // Once the carried turn says something and ends, its reply ends on its own row.
  const answered = [
    ...carried,
    row("r3", "assistant", { text: "Fixed the reconnect." }),
    row("sum2", "turnSummary", { status: "completed", durationMs: 5_000 }),
  ];
  const ended = turnView(answered, new Set(), options);
  const last = ended.find((each) => each.id === "sum2")!;
  expect(last.text).toBe("Fixed the reconnect.");
  expect(markup(last)).toContain(COPY);
});
