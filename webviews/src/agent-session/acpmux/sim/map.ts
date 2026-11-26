// l10n-allow-file: the chat simulator's scenario map, not shipped UI.
// The map of what a chat's display does wrong, or plausibly can, and what it should do instead
// (sim/README.md "The map").
//
// Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note
// what expected behaviours are for all."
//
// Each entry is one case: what happens, what has gone (or can go) wrong, the expected behaviour, the
// scenario that plays it, and a check of that behaviour on the run. `EVERYWHERE` holds what is expected
// of every chat whatever it plays. An entry with `open` is a known hole: nothing plays it yet, or the
// pane does not do the expected thing yet. test/chat-sim-map.test.ts runs the lot;
// `bun scripts/chat-sim.ts --map` prints it.
import type { RowProbe, SimResult, StepTrace } from "./run";

export type MapEntry = {
  id: string;
  /** What happens in the chat. */
  when: string;
  /** What has gone wrong here, or plausibly can. */
  wrong: string;
  /** What the reader should see. */
  expected: string;
  /** The `SCENARIOS` entry that plays it. */
  scenario?: string;
  /** The expected behaviour, checked on the scenario's run: one line per way it does not hold. */
  check?: (run: SimResult) => string[];
  /** A known hole: why nothing checks this yet, or what the pane still does instead. */
  open?: string;
};

const rowsOf = (step: StepTrace | undefined): RowProbe[] => step?.rows ?? [];
const last = (run: SimResult) => rowsOf(run.traces.at(-1));
const stepAt = (run: SimResult, label: string) => run.traces.findIndex((step) => step.label.startsWith(label));
/** The steps from the first whose label starts with `from` up to (not including) the next starting with `to`. */
const between = (run: SimResult, from: string, to: string): StepTrace[] => {
  const start = stepAt(run, from);
  if (start < 0) return [];
  const end = run.traces.findIndex((step, index) => index > start && step.label.startsWith(to));
  return run.traces.slice(start, end < 0 ? undefined : end);
};
const settled = (rows: RowProbe[]) => rows.filter((row) => !row.live).map((row) => `${row.id}:${row.fold}`);
const texts = (rows: RowProbe[]) => rows.map((row) => row.text ?? "");
const want = (ok: boolean, line: string) => (ok ? [] : [line]);
/** `steps` must exist, and no row may come, go or fold over them (the live line aside). */
const still = (steps: StepTrace[], what: string): string[] => {
  if (steps.length < 2) return [`${what}: the scenario no longer plays it`];
  const first = settled(rowsOf(steps[0])).join(" ");
  return steps
    .filter((step) => settled(rowsOf(step)).join(" ") !== first)
    .map((step) => `${what}: rows changed at "${step.label}"`);
};
/** Each row that landed above a row already drawn while its turn ran (the live line stays last, so
 *  landing over them is no landing). A reader's own step (opening a fold) is theirs. */
const landings = (run: SimResult): { label: string; id: string; kind: string; above: string }[] => {
  const out: { label: string; id: string; kind: string; above: string }[] = [];
  let before: StepTrace | undefined;
  for (const step of run.traces) {
    const was = before;
    before = step;
    if (!was?.rows || !step.rows || !was.working || !step.working || was.turn !== step.turn) continue;
    if (step.label.startsWith("reader ")) continue;
    const pinned = (row: RowProbe) => row.live;
    const old = new Set(was.rows.filter((row) => !pinned(row)).map((row) => row.id));
    const now = step.rows.filter((row) => !pinned(row));
    const lastOld = now.reduce((found, row, at) => (old.has(row.id) ? at : found), -1);
    now.forEach((row, at) => {
      if (!old.has(row.id) && at < lastOld)
        out.push({ label: step.label, id: row.id, kind: row.kind, above: now[lastOld]!.id });
    });
  }
  return out;
};
const isHeader = (kind: string) => kind === "worked" || kind === "working";
const landed = (found: { label: string; id: string; above: string }[]) =>
  found.map((each) => `${each.label}: ${each.id} landed above ${each.above}`);

/** Each drawn footer of an ended turn, by turn. */
const footers = (rows: RowProbe[]) => rows.filter((row) => row.kind === "turnSummary" && row.id.startsWith("summary-"));

/// What every chat keeps, whatever it plays. Checked on every scenario, on each as a reconnect reads it
/// (from halfway) and on a narrow pane.
export const EVERYWHERE: {
  id: string;
  expected: string;
  check: (run: SimResult) => string[];
  /** The scenarios that break it today, each by the map entry that says how. */
  known?: Record<string, string>;
}[] = [
  {
    id: "one-live-line",
    expected: "A working chat draws one live line, last. A chat at rest draws none.",
    check: (run) =>
      run.traces.flatMap((step) => {
        const rows = rowsOf(step);
        const live = rows.filter((row) => row.live);
        if (!step.working && live.length)
          return [`${step.label}: at rest, yet ${live.map((row) => row.id).join(", ")} is live`];
        if (live.length > 1) return [`${step.label}: ${live.length} live lines`];
        if (live.length === 1 && rows.at(-1) !== live[0])
          return [`${step.label}: ${live[0]!.id} is live above other rows`];
        return [];
      }),
  },
  {
    id: "row-ids-unique",
    expected: "No two drawn rows share an id (a shared id makes one row take the other's place and state).",
    check: (run) =>
      run.traces.flatMap((step) => {
        const ids = rowsOf(step).map((row) => row.id);
        const twice = ids.filter((id, index) => ids.indexOf(id) !== index);
        return twice.length ? [`${step.label}: ${[...new Set(twice)].join(", ")} drawn twice`] : [];
      }),
  },
  {
    id: "one-footer-a-turn",
    expected: "A turn that ended draws one footer, and it stays.",
    check: (run) => {
      const out: string[] = [];
      const seen = new Set<string>();
      for (const step of run.traces) {
        if (!step.rows) continue;
        const ids = footers(step.rows).map((row) => row.id);
        for (const id of seen) if (!ids.includes(id)) out.push(`${step.label}: footer ${id} left`);
        for (const id of ids) seen.add(id);
      }
      return out;
    },
  },
  {
    id: "prompt-stays",
    expected: "The person's prompt, once drawn, is never taken away or moved under a fold.",
    check: (run) => {
      const out: string[] = [];
      const seen = new Set<string>();
      for (const step of run.traces) {
        if (!step.rows) continue;
        const ids = new Set(step.rows.map((row) => row.id));
        for (const id of seen) if (!ids.has(id)) out.push(`${step.label}: prompt ${id} left`);
        for (const row of step.rows) if (row.kind === "user" && row.opens && !row.received) seen.add(row.id);
      }
      return out;
    },
  },
  {
    id: "rows-only-append",
    expected:
      "While a turn runs, a new row lands under the rows already drawn (over the live line, which stays last): never between or above them, which pushes drawn rows down. The turn's header line has its own entry (header-arrives-late).",
    check: (run) => landed(landings(run).filter((each) => !isHeader(each.kind))),
    known: {
      "received-sent-as-activity": "received-drawn-late",
      "steer-mid-turn": "cut-reply-footer-late",
      "permission-wait": "denial-receipt-order",
    },
  },
  {
    id: "rest-is-quiet",
    expected: "Once the last turn ended, its footer is drawn last and nothing above reads as still running.",
    check: (run) => {
      const end = run.traces.at(-1);
      if (!end?.rows || end.working || !end.turnEnded) return [];
      return want(end.rows.at(-1)?.kind === "turnSummary", `the chat rests on ${end.rows.at(-1)?.kind}, not a footer`);
    },
  },
];

export const MAP: MapEntry[] = [
  // ---- Gaps and folds: the three rules (README "The rules"), on the shapes Leo reported. ----
  {
    id: "plain-turn",
    when: "One prompt: a thought, commands with text between, a reply.",
    wrong: "Rows folded mid-turn; the head stood flush under the prompt.",
    expected: "Rules a, b, c: the head stands the block gap under the prompt, and nothing folds until the turn ends.",
    scenario: "basic",
  },
  {
    id: "incoming-opens-turn",
    when: "Another agent's notice or message starts a turn.",
    wrong: 'Leo, 2026-11-21: "Working for" stood flush (0px) under the notice.',
    expected: "The opening line stands 24 under the turn before; Thinking and Working for stand the head gap under it.",
    scenario: "incoming-notice-turn",
  },
  {
    id: "incoming-message-opens-turn",
    when: "Another agent's message starts a turn after a turn that ended on a reply.",
    wrong: "The message sat 16 under the last reply (37 chats in the first sweep).",
    expected: "The message stands 24 under the reply before it, and the head gap holds under it.",
    scenario: "incoming-message-turn",
  },
  {
    id: "long-turn-folds",
    when: "One long turn: text, runs of commands, a long wait, more runs.",
    wrong:
      'Leo, 2026-11-21: "the messages and whatever collapsing and stuff, sometimes it does so too soon in the midst of a turn".',
    expected: "Rule b: a run closes only under the agent's next paragraph; nothing else folds before the turn ends.",
    scenario: "long-turn-messages",
  },
  {
    id: "received-and-sent-rows",
    when: "A turn receives another agent's message mid-turn and sends some.",
    wrong: 'Leo, 2026-11-22: "an unnecessary gap due to being a recieved message".',
    expected: "Received and Sent to rows stand exactly a tool row's gap, at every step.",
    scenario: "received-sent-as-activity",
  },
  {
    id: "messages-steer-mid-turn",
    when: "Other agents' messages steer into a running turn between its commands, two back to back.",
    wrong:
      'Leo, 2026-11-22: "sometimes you get these way-too-big gaps. i think it\'s the message recieving not properly getting treated like the tool call ish thing it should be".',
    expected: "Rule d: each received line sits on the tool rows' pitch, at most a step's gap from its neighbours.",
    scenario: "messages-mid-turn",
  },
  {
    id: "background-shell",
    when: "A turn leaves a shell running; it ends later and the agent works on its own.",
    wrong: "The agent's own turn drew no head, or its line pinned under the turn before.",
    expected: "Rules a, b: the background turn's rows keep their gaps; nothing of the ended turn folds or moves.",
    scenario: "background-task",
  },
  {
    id: "subagent",
    when: "A turn starts a subagent and works beside it.",
    wrong: "The subagent's row folded away while it still ran.",
    expected: "Rule b: the subagent's row stays drawn, open, until the turn ends.",
    scenario: "subagent",
  },
  {
    id: "subagent-fork",
    when: "A chat forked from a subagent (Fork with <model>… on its composer chips) opens on the subagent's history.",
    wrong: "The Forked from line could land inside the history's turn, or the fork's own turn fold into it.",
    expected:
      "Rules a, b, c: the subagent's history keeps its turn, the Forked from line stands between it and the fork's own turn, which folds only when it ends.",
    scenario: "subagent-fork",
  },
  {
    id: "compaction-mid-turn",
    when: "The agent compacts its context halfway through a turn.",
    wrong: "The compaction line split the run around it and closed it early.",
    expected: "Rule b: a compaction line inside a run folds with the run, not before.",
    scenario: "compaction",
  },
  {
    id: "reader-scrolled-up",
    when: "The reader scrolls to the top while a turn runs and ends.",
    wrong: "Rows the reader was looking at were rebuilt or folded under them.",
    expected: "Rules b, c: held folds stay as they were while scrolled up; rows two turns back are not rebuilt.",
    scenario: "reader-scroll",
  },

  // ---- How a turn ends. ----
  {
    id: "stopped-turn",
    when: "The person stops a turn while a command runs, then prompts again.",
    wrong: "The stopped turn kept a live line or a running command; the reply written before the stop went away.",
    expected:
      "The turn's line and footer read cancelled, the reply written before the stop stays drawn, no command reads as running, and the next prompt stands the turn gap under it.",
    scenario: "stopped-turn",
    check: (run) => {
      const rows = last(run);
      const head = rows.find((row) => row.id === "worked-user-1");
      const footer = footers(rows)[0];
      const next = rows.find((row) => row.opens && row.turn === 2);
      return [
        ...want(head?.status === "cancelled", `the stopped turn's line reads ${head?.status}`),
        ...want(footer?.status === "cancelled", `the stopped turn's footer reads ${footer?.status}`),
        ...want(
          texts(rows).includes("The slow tests pass; running the rest."),
          "the reply before the stop is not drawn",
        ),
        ...want(!rows.some((row) => row.running), "a command of the stopped turn still reads as running"),
        ...want((next?.gap ?? 0) >= 32, `the next prompt stands ${next?.gap}px under the stopped turn`),
      ];
    },
  },
  {
    id: "failed-turn",
    when: "A turn fails halfway through its work (the model's API errors), and the next prompt carries on.",
    wrong: "The error showed nowhere, or took the text written before it away.",
    expected:
      "The footer carries the error and reads failed, the text written before it stays, and the next turn is ordinary.",
    scenario: "failed-turn",
    check: (run) => {
      const rows = last(run);
      const [first, second] = footers(rows);
      return [
        ...want(
          first?.status === "failed" && first.error === true,
          `the failed turn's footer reads ${first?.status}, error ${first?.error}`,
        ),
        ...want(texts(rows).includes("Two callers left."), "the text written before the failure is not drawn"),
        ...want(second?.status === "completed" && !second.error, "the next turn's footer carries the failure"),
      ];
    },
  },
  {
    id: "lost-result",
    when: "A command's result never arrives (the harness died, a record was lost): the turn ends with the call open.",
    wrong: 'The command reads "Running …" for ever inside a finished turn.',
    expected: "Once its turn ended, no foreground command reads as running.",
    scenario: "lost-result",
    check: (run) => {
      // The reader opens the ended turn: what its rows say.
      const rows = last(run);
      return want(!rows.some((row) => row.turn === 1 && row.running), "a command of the ended turn reads as running");
    },
    open: "The pane keeps the call as running: nothing settles a call left open at its turn's end. Not seen in 13 recorded lane chats (1,500 calls); a harness crash would do it.",
  },
  {
    id: "compaction-at-turn-end",
    when: "A compaction is still running when the turn ends; it completes in the next turn.",
    wrong: "A compaction line stayed spinning in the ended turn, or drew twice.",
    expected: "The ended turn folds whole; the next turn draws one compaction line and folds it with its work.",
    scenario: "compaction-at-end",
    check: (run) => {
      const most = Math.max(
        ...run.traces.map((step) => rowsOf(step).filter((row) => row.kind === "compaction").length),
      );
      return [
        ...want(most <= 1, `${most} compaction lines drawn at once`),
        ...want(
          !last(run).some((row) => row.kind === "compaction"),
          "a compaction line is still drawn after both turns ended",
        ),
      ];
    },
  },
  {
    id: "turn-with-one-thing",
    when: "A turn that only thinks, one that only runs a command, one that only replies.",
    wrong: "A turn with no reply drew nothing under its prompt, or a footer with no line over it.",
    expected:
      "Thought-only and command-only turns draw their Worked for line; a reply-only turn draws the reply with no Worked for line.",
    scenario: "thought-only-turn",
    check: (run) => {
      const kinds = (turn: number) =>
        last(run)
          .filter((row) => row.turn === turn)
          .map((row) => row.kind)
          .join(" ");
      return [
        ...want(kinds(1) === "user worked turnSummary", `the thought-only turn draws: ${kinds(1)}`),
        ...want(kinds(2) === "user worked turnSummary", `the command-only turn draws: ${kinds(2)}`),
        ...want(kinds(3) === "user assistant turnSummary", `the reply-only turn draws: ${kinds(3)}`),
      ];
    },
  },
  {
    id: "empty-turn",
    when: "A turn ends having drawn nothing, between two ordinary turns.",
    wrong: "The empty turn drew a Worked for line over nothing, or the next prompt lost its gap.",
    expected: "The empty turn draws its prompt and its footer only, and the next prompt stands the turn gap under it.",
    scenario: "empty-turn",
    check: (run) => {
      const rows = last(run);
      const empty = rows.filter((row) => row.turn === 2).map((row) => row.kind);
      const next = rows.find((row) => row.opens && row.turn === 3);
      return [
        ...want(empty.join(" ") === "user turnSummary", `the empty turn draws: ${empty.join(" ")}`),
        ...want((next?.gap ?? 0) >= 32, `the next prompt stands ${next?.gap}px under the empty turn`),
      ];
    },
  },

  // ---- What comes in while a turn runs. ----
  {
    id: "retrying",
    when: "The model cannot be reached mid-turn; acpmux retries, then hears it again.",
    wrong:
      'The live line read "Thinking" through an outage (Leo, 2026-11-03), or rows jumped as the retry came and went.',
    expected: "While it retries, only the live line changes: no row comes, goes or folds.",
    scenario: "retrying-turn",
    check: (run) => still(between(run, "turn_retrying 1", "tool start"), "retrying"),
  },
  {
    id: "steer",
    when: "The person types twice while the turn runs: between commands, and while a reply streams.",
    wrong: "A steer opened a new turn, cut the streaming reply in two with text lost, or vanished when the turn ended.",
    expected:
      "Each steer is drawn where it landed and stays; the whole thing is one turn with one footer; the reply after a steer starts below it.",
    scenario: "steer-mid-turn",
    check: (run) => {
      const out: string[] = [];
      for (const text of ["Keep the public signature as it is.", "And add a test."]) {
        const from = run.traces.findIndex((step) => texts(rowsOf(step)).includes(text));
        if (from < 0) out.push(`the steer "${text}" is never drawn`);
        else if (!run.traces.slice(from).every((step) => texts(rowsOf(step)).includes(text)))
          out.push(`the steer "${text}" left after it was drawn`);
      }
      const rows = last(run);
      const order = [
        "Keep the public signature as it is.",
        "And add a test.",
        "Refactored, signature kept, test added.",
      ].map((text) => texts(rows).indexOf(text));
      return [
        ...out,
        ...want(new Set(run.traces.map((step) => step.turn)).size === 1, "a steer counted as a new turn"),
        ...want(footers(rows).length === 1, `${footers(rows).length} turn footers for one turn`),
        ...want(
          order.every((at, index) => at >= 0 && (index === 0 || at > order[index - 1]!)),
          `steers and the answer are out of order: ${order.join(", ")}`,
        ),
      ];
    },
  },
  {
    id: "queued-prompt",
    when: "A prompt sent while the turn runs waits in the queue, then runs as the next turn.",
    wrong: "The queued prompt drew in the transcript while it waited, then again when it ran.",
    expected:
      "While it waits it is not a transcript row (the composer's queue holds it); when it runs it is drawn once, opening its turn at the turn gap.",
    scenario: "queued-prompt",
    check: (run) => {
      const text = "Then run the tests.";
      const waiting = between(run, "queued", "prompt: Then run");
      const drawn = last(run).filter((row) => row.text === text);
      return [
        ...want(waiting.length > 0, "the scenario no longer queues"),
        ...waiting
          .filter((step) => texts(rowsOf(step)).includes(text))
          .map((step) => `${step.label}: the queued prompt is a transcript row`),
        ...want(
          drawn.length === 1 && drawn[0]!.opens === true && drawn[0]!.gap >= 32,
          `the prompt is drawn ${drawn.length} times (gap ${drawn[0]?.gap})`,
        ),
      ];
    },
  },
  {
    id: "permission-wait",
    when: "A command waits on the person's Allow for half a minute, runs, and a second one is denied.",
    wrong: "The transcript jumped when the card came or went; a denied command read as running.",
    expected:
      "Waiting on Allow and allowing change no transcript row (the card is the composer's); a denial leaves one receipt, nothing reads as running after it and the turn goes on.",
    scenario: "permission-wait",
    check: (run) => [
      ...still(between(run, "permission asked: call-1", "tool completed: call-1"), "waiting on Allow"),
      ...want(
        last(run).filter((row) => row.kind === "permissionRecord").length <= 1,
        "a permission receipt is drawn twice",
      ),
      ...want(!last(run).some((row) => row.running), "a command reads as running after the turn ended"),
    ],
  },

  {
    id: "incoming-burst",
    when: "Five notices and messages from other agents in a row: some answered in a line, one with a command.",
    wrong: "Lines stacked flush or doubled their gaps.",
    expected:
      "Each is its own turn with one footer, and each turn's first row stands the 24 gap under the turn before.",
    scenario: "incoming-burst",
    check: (run) => {
      const rows = last(run);
      const firsts = [2, 3, 4, 5, 6].map((turn) => rows.find((row) => row.turn === turn));
      return [
        ...want(footers(rows).length === 7, `${footers(rows).length} footers for 7 turns`),
        ...firsts.flatMap((row, index) =>
          want(row?.gap === 24, `turn ${index + 2} opens ${row?.gap}px under the turn before`),
        ),
      ];
    },
  },
  {
    id: "silent-received-flush",
    when: "Another agent's line gets no answer at all, and a second one arrives right under it.",
    wrong: "Chrome draws the second line flush under the first (0px), and its Worked for 16px under it.",
    expected: "The second line opens its turn the 24 gap under the first, answered or not.",
    open: "Seen in Chrome only (the model run measures 24): the scenario that plays it turns the browser lane red, so it is not in SCENARIOS until the fix.",
  },

  // ---- Size. ----
  {
    id: "long-output",
    when: "A command prints 4,000 lines and the reply is fifty paragraphs with tables and code.",
    wrong: "Long output drew as rows of its own or pushed the reply; a long reply was split across rows.",
    expected: "The same rows as a short turn: one line for the command, one row for the reply, however long either is.",
    scenario: "long-output",
    check: (run) => {
      const most = Math.max(...run.traces.map((step) => step.rowCount));
      return want(most <= 7, `${most} rows drawn at once for a turn of two commands and two replies`);
    },
  },
  {
    id: "parallel-commands",
    when: "Four commands start together and end out of order, one failing.",
    wrong: "Each command drew a run of its own, or the run reordered as results came.",
    expected:
      "One run takes each command as it ends (a running one is the live line's), holds all four at the end, and never loses or reorders one.",
    scenario: "parallel-tools",
    check: (run) => {
      const out: string[] = [];
      let held = 0;
      for (const step of between(run, "tool start: bun test api/", "assistant delta")) {
        const runs = rowsOf(step).filter((row) => row.kind === "activity");
        if (runs.length > 1) out.push(`${step.label}: ${runs.length} runs for one batch of commands`);
        const calls = runs[0]?.calls ?? 0;
        if (calls < held) out.push(`${step.label}: the run went from ${held} commands to ${calls}`);
        held = calls;
      }
      return [
        ...out,
        ...want(held === 4, `the run holds ${held} of the four commands once all ended`),
        ...want(!last(run).some((row) => row.running), "a command reads as running after the turn ended"),
      ];
    },
  },
  {
    id: "long-chat",
    when: "Thousands of turns over hours (longRun).",
    wrong: "Each step cost more as the chat grew; old rows were rebuilt.",
    expected: "Rule b on 10k+ rows; a step shapes about a turn's rows however long the chat is.",
    open: "Played by longRun in test/chat-sim.test.ts, not a named scenario.",
  },

  // ---- Helpers and the reader. ----
  {
    id: "failed-helpers",
    when: "A subagent fails, and a background shell exits non-zero after its turn ended.",
    wrong: "A failure after the turn ended reopened the turn or drew a stray line under its footer.",
    expected: "The ended turn's drawn rows stay as they were when the shell fails; nothing reads as running.",
    scenario: "failed-helpers",
    check: (run) => [
      ...still(between(run, "status ready", "prompt: Did the server"), "a shell failing after its turn"),
      ...want(!last(run).some((row) => row.running), "a command reads as running after the turn ended"),
    ],
  },
  {
    id: "reader-opens-fold",
    when: "The reader opens an ended turn's Worked for while the next turn runs.",
    wrong: "The fold closed by itself on the next record, or when the running turn ended.",
    expected: "A fold the reader opened stays open until they close it.",
    scenario: "reader-opens-mid-turn",
    check: (run) => {
      const from = stepAt(run, "reader open");
      return run.traces
        .slice(from < 0 ? run.traces.length : from)
        .filter((step) => rowsOf(step).find((row) => row.id === "worked-user-1")?.fold !== "open")
        .map((step) => `${step.label}: the fold the reader opened is closed`)
        .concat(want(from >= 0, "the scenario no longer opens the fold"));
    },
  },
  {
    id: "codex-final-answer",
    when: "A Codex turn: commentary between commands, then the final answer.",
    wrong: "Commentary folded mid-turn with no answer under it, or the final answer folded with it.",
    expected:
      "Commentary folds under Worked for only as the final answer streams (verdict final-answer); the answer is drawn at the end.",
    scenario: "codex-turn",
    check: (run) =>
      want(
        last(run).some((row) => row.kind === "assistant" && (row.text ?? "").startsWith("Fixed: the loop")),
        "the final answer is not drawn",
      ),
  },

  // ---- Rows that land late: found by rows-only-append on the scenarios above. Each is open. ----
  {
    id: "header-arrives-late",
    when: "A turn opens with text (or a compaction line) and starts its first command after.",
    wrong:
      'The "Working for" line is drawn only once the turn\'s first command or thought starts, above the text already there, which moves down by a line.',
    expected: "The turn's header line never lands above a row the turn already drew.",
    scenario: "subagent",
    check: (run) => landed(landings(run).filter((each) => isHeader(each.kind))),
    open: "The pane adds the header with the turn's first work row: long-turn-messages, subagent, compaction-at-end and codex-turn all show it.",
  },
  {
    id: "received-drawn-late",
    when: "Another agent's message arrives between two commands of a running turn.",
    wrong:
      "The message is not drawn when it arrives: it appears when the agent's next paragraph starts, above the commands run since.",
    expected: "A message received mid-turn is drawn at the step it arrives, under the rows already there.",
    scenario: "received-sent-as-activity",
    check: (run) => {
      const arrives = stepAt(run, "message from");
      const drawn = run.traces.findIndex((step) =>
        rowsOf(step).some((row) => row.message === "received" && !row.opens && row.turn === 3),
      );
      return [
        ...want(arrives >= 0, "the scenario no longer receives a message mid-turn"),
        ...want(drawn === arrives, `received at step ${arrives}, drawn at step ${drawn}`),
        ...landed(landings(run).filter((each) => !isHeader(each.kind))),
      ];
    },
    open: "The pane holds the received line until the run of commands around it closes.",
  },
  {
    id: "cut-reply-footer-late",
    when: "The person types while a reply streams; the reply finishes over their message and the agent goes on.",
    wrong:
      "The finished reply's footer is drawn only when the next command starts, between the reply and the person's message, which moves down.",
    expected: "Nothing lands between a reply and the message typed under it once both are drawn.",
    scenario: "steer-mid-turn",
    check: (run) => landed(landings(run).filter((each) => !isHeader(each.kind))),
    open: "The pane adds the cut reply's footer (superseded-…) when the reply's segment ends, after the steer's row is drawn under it.",
  },
  {
    id: "denial-receipt-order",
    when: "The person denies a command.",
    wrong: "The denial's receipt is drawn first; the denied command's line lands above it a moment later.",
    expected: "A denied command's line and its receipt are drawn in the order they stay in.",
    scenario: "permission-wait",
    check: (run) => landed(landings(run).filter((each) => !isHeader(each.kind))),
    open: "A command's line is drawn when it ends (a running one is the live line's), and the receipt is drawn at the answer, before the denied call ends.",
  },

  // ---- Not played yet. `bun scripts/chat-sim.ts --drift DIR` lists the record kinds no scenario or fixture plays. ----
  {
    id: "offline",
    when: "The host goes away mid-turn and comes back (host_notice, failover), or the pane reconnects.",
    wrong: "Rows doubled after the reconnect; the live line ran on through the outage.",
    expected: "The transcript after a reconnect is the one an unbroken read draws.",
    open: "No scenario writes host_notice or failover records. A later page's read is checked: every scenario is also played from the turn that opens nearest its middle (test/chat-sim-map.test.ts), as the pane's pages split (before a turn's opening record). A read cut inside a turn, which no page makes, leaves the typing placeholder over the turn's rows.",
  },
  {
    id: "busy-turn-churn",
    when: "A busy coordinator turn: quick commands, thoughts, steers that land mid-turn, subagents in and out, another agent's message, then a prompt right after the turn settles.",
    wrong:
      'Leo, 2026-11-22: "this is also a crazy situation for the folding and whatever the steer and you think and messages and situations come in and subagents come in and out"; rows flickered in and out under a second.',
    expected:
      "Rules a, b, c at every step; in the browser lane, no layout shift above the reader's anchor mid-turn and no row drawn for under a second (`chat-sim churn --churn` counts both per minute).",
    scenario: "churn",
  },
  {
    id: "limits-and-refusals",
    when: "A usage limit, a refused prompt, a superseded message (usage_limits, prompt_refused, message_superseded).",
    wrong: "A refused prompt stayed drawn as sent; a limit line drew once per retry.",
    expected: "A refused prompt goes back to the composer and leaves no row; a limit draws one line.",
    open: "Not played: the records are written by acpmux paths no scenario scripts yet.",
  },
  {
    id: "cards",
    when: "A session offer, a secret request, a memory offer, a subsession or a fork lands mid-turn.",
    wrong: "A card landed between a run and its reply and broke the fold, or stood the wrong gap.",
    expected: "A card is a block: 24 over it, and it folds nothing.",
    open: "Not played: session_offer, secret_request, memory_offer, subsession, forked.",
  },
  {
    id: "drawn-size",
    when: "A reply's Markdown reflows as it streams (a half table, a code fence), an image loads, the pane narrows.",
    wrong: "Rows above the reader moved as heights changed.",
    expected:
      "A row of a running turn never draws 12px shorter than the step before with its fold unchanged (b-mid-turn-shrink).",
    open: "Heights are drawn only in Chrome: the browser lane (test/chat-sim-browser.test.ts) plays every scenario here, on CI. The model run plays each scenario at a narrow width too.",
  },
];
