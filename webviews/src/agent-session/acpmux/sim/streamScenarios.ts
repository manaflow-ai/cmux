// l10n-allow-file: simulated chat fixtures for the chat simulator, not shipped UI.
// The chat pane's scenario map, executable (docs/design/chat-stream-scenarios.md). Each scenario has an id, the
// behaviour expected of it, who owns it, and how it runs:
//   - `sim`: the model run (run.ts): the pane's reducer, turn view and layout on virtual time, rules (a)(b)(c) and
//     the bubble-integrity rules (integrity.ts) checked at every step;
//   - `live`: the same records through a connected client and a fake acpmux (bench/stateGrowth.ts FakeDaemon), for
//     what only a live connection does: duplicates, reordering, a dropped socket, a summary that ends a turn;
//   - `elsewhere`: a behaviour the model cannot see (pixels, motion, focus, input): the test that holds it, named.
//
// Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note what
// expected behaviours are for all. idek."
import type { EventRecord } from "../direct";
import { SCENARIOS } from "./scenarios";
import { sim, type SimBuilder, type SimScenario, SIM_SESSION } from "./script";
import type { IntegrityRule } from "./integrity";

export type Axis = "stream" | "transport" | "view" | "timing" | "markdown" | "status";

/** What a live case does to the connection while the records arrive (bench/stateGrowth.ts FakeDaemon). */
export type LiveStep =
  | { push: number }
  | { duplicate: number }
  | { swap: [number, number] }
  | { drop: true }
  | { summary: Record<string, unknown> }
  | { reopen: true }
  | { advance: number };

export type StreamScenario = {
  id: string;
  axis: Axis;
  title: string;
  expected: string;
  /** Who fixes it when it fails: a lane, a helper or a PR. */
  owner: string;
  harness: "sim" | "live" | "elsewhere";
  make?: () => SimScenario;
  /** live: the records, then what happens to the connection; each `push: N` delivers records up to index N. */
  live?: { records: () => SimScenario; steps: (events: EventRecord[]) => LiveStep[] };
  /** Rules this scenario does not hold by design (a cancelled reply may stop inside `**`). */
  exempt?: IntegrityRule[];
  /** elsewhere: the test or check that holds it. */
  heldBy?: string;
};

const P1 =
  "I read the retry helper and the test that covers it. The loop allows one attempt too many, so the test that counts calls sees four instead of three.";
const P2 =
  "The fix bounds the loop by `attempts` and makes the first retry wait the base delay, so the test sees exactly three calls now.";
// Leo's screenshot (images/1158.png): the cut sat inside "**GUI paths:**".
const BOLD =
  "Two paths matter here. **GUI paths:** includes forking while the turn runs, and the reply keeps going after it.";

const own = {
  split: "helper ae03a5b84e9c36fd5 (split and duplicate reply)",
  sim: "chat-scenarios (this map)",
  blank: "pane-blank owner (#47553 lane/chat-tab-switch-keeps-frame)",
  shift: "layout-shift owner (gcp-agent-lane-4/ask-cdfac12eab, #45741)",
  icons: "late-icons owner (#49963 fix/turn-action-row-pop-in)",
  since: "since-you-were-here owner (#49873/#49876/#49891, session 1fa5e901)",
  follow: "stream-follow owner (#49596 lane/stream-follow-smooth)",
  fold: "turn-end fold owner (#48663 lane/chat-mid-turn-shrink)",
  received: "received-rows helper (lane/chat-received-as-activity, ST-02)",
  shimmer: "shimmer helper (lane/chat-status-shimmer, ST-03/ST-04)",
  composer: "composer caret (#49439 composer-typing-lag)",
  delivery: "transcript delivery (manaflow-ai/cmuxterm-hq#8950)",
  inbox: "#49992 inbox-row-gap",
};

const turn = (name: string, about: string, body: (b: SimBuilder) => void, family?: string) => () => {
  const b = sim(name, about, family);
  b.prompt("Fix the flaky retry test.");
  body(b);
  return b.build();
};

/// A reply streamed as one message (one messageId, one segment), as acpmux stamps it.
const msg = (b: SimBuilder, text: string, id: string, options: Parameters<SimBuilder["say"]>[1] = {}) =>
  b.say(text, { messageId: id, segment: `${id}.1.1`, ...options });

// ---------- timing: every event at every moment of a turn ----------

/** The moments in a turn an event can land at. */
const MOMENTS = [
  "before-first-chunk",
  "mid-bold",
  "between-paragraphs",
  "during-tool",
  "after-tool",
  "after-turn-end",
] as const;
/** The events that can land there. */
const EVENTS = ["steer", "incoming", "permission", "background-end", "compaction", "long-pause", "tool"] as const;

function placed(event: (typeof EVENTS)[number], b: SimBuilder): void {
  switch (event) {
    case "steer":
      b.steerPrompt("Also check the second caller.");
      break;
    case "incoming":
      // Another agent's message arriving mid-turn is a steer-like prompt into the running turn.
      b.record(
        "mux",
        "user_message",
        {
          text: "Heads up: main moved.",
          promptId: `in-${b.events.length}`,
          turnId: b.current().turnId,
          client: "acpmux-cli#1",
          steer: true,
          _meta: { provenance: { kind: "agent_message", from: "sim-host/coord", fromName: "coord" } },
        },
        300,
        "incoming mid-turn",
      );
      break;
    case "permission":
      b.permissionCard("rm -rf build/");
      break;
    case "background-end":
      b.backgroundEnds();
      break;
    case "compaction":
      b.compaction();
      break;
    case "long-pause":
      b.wait(90_000);
      break;
    case "tool":
      b.tool("bun test api", { ms: 1_200 });
      break;
  }
}

/** Events that end a reply segment (acpmux hub/stream.rs `cuts_reply`, the pane's `endAssistantSegment`). */
const REAL_BOUNDARY = new Set<string>(["steer", "permission", "compaction", "tool"]);

function timingCase(event: (typeof EVENTS)[number], moment: (typeof MOMENTS)[number]): () => SimScenario {
  return () => {
    const b = sim(`tm-${event}-${moment}`, `${event} lands ${moment}`);
    b.prompt("Fix the flaky retry test.");
    b.background("bun run watch", { ms: 1 });
    if (moment === "before-first-chunk") placed(event, b);
    b.think("Reading the helper.");
    if (moment === "mid-bold") {
      const cut = BOLD.indexOf("paths:") + 3;
      b.say(BOLD.slice(0, cut), { messageId: "m1", segment: "m1.1.1", chunks: 2 });
      placed(event, b);
      // After a real boundary the harness writes a new message (a tool's result starts the model's next one).
      const next = REAL_BOUNDARY.has(event) ? "m1b" : "m1";
      b.say(BOLD.slice(cut), { messageId: next, segment: `${next}.1.1`, chunks: 2 });
    } else msg(b, P1, "m1");
    if (moment === "between-paragraphs") placed(event, b);
    b.tool("rg -n retry src", { open: moment === "during-tool", ms: 800 });
    if (moment === "during-tool") {
      placed(event, b);
      b.toolEnd("call-2", { ms: 400 });
    }
    if (moment === "after-tool") placed(event, b);
    msg(b, P2, "m2");
    b.turnEnd();
    if (moment === "after-turn-end") placed(event, b);
    return b.build();
  };
}

const timing: StreamScenario[] = EVENTS.flatMap((event) =>
  MOMENTS.map((moment): StreamScenario => ({
    id: `TM-${event}@${moment}`,
    axis: "timing",
    title: `${event} lands ${moment.replace(/-/g, " ")}`,
    expected:
      "One message stays one bubble; nothing folds before turn_result; a turn's first rows keep their gaps; no row two turns back is rebuilt; nothing sent is lost or drawn twice; an ended turn draws no placeholder.",
    owner: own.sim,
    harness: "sim",
    make: timingCase(event, moment),
    // A real boundary inside `**bold**` cuts the reply into two rows, each drawn as written. No harness does this
    // (text ends before a tool call, a compaction or a permission ask; a steer is read between steps), so the cut
    // span is accepted here; a pause, a background end or another agent's message inside bold must not cut it.
    ...(moment === "mid-bold" && REAL_BOUNDARY.has(event)
      ? { exempt: ["i-unclosed-markdown", "i-split-bubble"] as IntegrityRule[] }
      : {}),
  })),
);

// ---------- the map ----------

export const STREAM_SCENARIOS: StreamScenario[] = [
  // Stream events
  {
    id: "SE-01",
    axis: "stream",
    title: "Text deltas, one reply",
    expected: "One bubble grows in place; rows above never move; text equals what was sent.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-01", "one reply in deltas", (b) => {
      msg(b, `${P1}\n\n${P2}`, "m1", { chunks: 12 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-02",
    axis: "stream",
    title: "Short pause (2 s) mid-reply",
    expected: "Same bubble resumes; no fold, no Worked for, no new row; the live line keeps Working for.",
    owner: own.split,
    harness: "sim",
    make: turn("se-02", "a 2 s stall inside a reply", (b) => {
      msg(b, `${P1} ${P2}`, "m1", { chunks: 8, pauseAt: 4, pauseMs: 2_000 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-03",
    axis: "stream",
    title: "Long pause (90 s) mid-reply, same message",
    expected:
      "Same bubble resumes after the pause; a pause is never a step boundary; no fold until turn_result (Leo's 1158).",
    owner: own.split,
    harness: "sim",
    make: turn("se-03", "a 90 s stall inside a reply", (b) => {
      msg(b, `${P1} ${P2}`, "m1", { chunks: 8, pauseAt: 4, pauseMs: 90_000 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-04",
    axis: "stream",
    title: "Long pause inside **bold** (Leo's 1158 shape)",
    expected: "One bubble; the bold span closes in the same bubble; no Worked for between halves.",
    owner: own.split,
    harness: "sim",
    make: turn("se-04", "a 14 s stall inside **bold**", (b) => {
      msg(b, BOLD, "m1", { split: [BOLD.indexOf("paths:") + 3], pauseAt: 1, pauseMs: 14_000 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-05",
    axis: "stream",
    title: "Thinking, then the reply",
    expected:
      "The thought sits in the turn's activity (live line reads Thinking, shimmering); the reply is one bubble under it.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-05", "a thought then a reply", (b) => {
      b.think("Reading the helper first, then the test.", { chunks: 5 });
      msg(b, P1, "m1");
      b.turnEnd();
    }),
  },
  {
    id: "SE-06",
    axis: "stream",
    title: "Tool call between two paragraphs",
    expected:
      "Paragraph, tool row, paragraph: a real boundary, so two bubbles are right; the run folds only at turn end (or under the next paragraph, #48597).",
    owner: own.sim,
    harness: "sim",
    make: turn("se-06", "a call between two replies", (b) => {
      msg(b, P1, "m1");
      b.tool("bun test api/client.test.ts", { ms: 1_500 });
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-07",
    axis: "stream",
    title: "Tool call running for a minute",
    expected: "The call row stays live (shimmer, elapsed time); nothing above moves; it settles in place when it ends.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-07", "a long call", (b) => {
      b.tool("bun test --all", { open: true });
      b.wait(60_000).toolEnd("call-1", { ms: 0 });
      msg(b, P2, "m1");
      b.turnEnd();
    }),
  },
  {
    id: "SE-08",
    axis: "stream",
    title: "Nested subagent",
    expected: "One subagent row, live while it runs, its own work inside it; the parent's reply stays one bubble.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS.subagent,
  },
  {
    id: "SE-09",
    axis: "stream",
    title: "Permission card mid-turn",
    expected:
      "The card draws in the bottom stack (not in the transcript); once answered, a one-line receipt row; the reply before it is whole.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-09", "a permission card between replies", (b) => {
      msg(b, P1, "m1");
      b.permissionCard("git push --force");
      b.tool("git push --force", { ms: 800 });
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-10",
    axis: "stream",
    title: "Ask card (AskUserQuestion)",
    expected:
      "The question draws as a card while open, then one question record row with the answer; no mid-turn fold.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-10", "an ask card", (b) => {
      msg(b, P1, "m1");
      b.ask("Which branch?", ["main", "feat-cmux-next"]);
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-11",
    axis: "stream",
    title: "Turn end",
    expected:
      "Work folds into one Worked for line at turn_result, in one motion (exit before move); the final reply stays; no placeholder; footer icons the same frame.",
    owner: own.fold,
    harness: "sim",
    make: SCENARIOS.basic,
  },
  {
    id: "SE-12",
    axis: "stream",
    title: "False turn end: the summary says ended, then more chunks",
    expected:
      "A turn ends only on turn_end/turn_result for its id; a stale summary mid-stream never closes the bubble or draws Worked for.",
    owner: own.split,
    harness: "live",
    live: {
      records: turn("se-12", "summary ends the turn mid-reply", (b) => {
        msg(b, BOLD, "m1", { split: [BOLD.indexOf("paths:") + 3] });
        b.turnEnd();
      }),
      steps: (events) => {
        const cut = events.findIndex((event) => event.kind === "agent_message_chunk") + 1;
        return [
          { push: cut },
          { summary: { status: "ready", turn: null } },
          { advance: 14_000 },
          { push: events.length },
        ];
      },
    },
  },
  {
    id: "SE-13",
    axis: "stream",
    title: "Turn fails (error)",
    expected: "The partial reply stays as written; one error row says why, with Retry; no placeholder; nothing lost.",
    owner: own.sim,
    harness: "sim",
    exempt: ["i-unclosed-markdown"],
    make: turn("se-13", "a failed turn", (b) => {
      msg(b, P1, "m1");
      b.turnEnd("failed");
    }),
  },
  {
    id: "SE-14",
    axis: "stream",
    title: "Stop (cancel) mid-reply",
    expected:
      "The reply stops where it was, drawn closed (the renderer closes an open span); a Stopped marker; no placeholder; Stop gone the same frame.",
    owner: own.sim,
    harness: "sim",
    exempt: ["i-unclosed-markdown"],
    make: turn("se-14", "a stop mid-bold", (b) => {
      msg(b, BOLD.slice(0, BOLD.indexOf("paths:") + 3), "m1");
      b.turnEnd("cancelled");
    }),
  },
  {
    id: "SE-15",
    axis: "stream",
    title: "Steer sent mid-reply",
    expected:
      "The words before the steer stay above it; the steer bubble shows Waiting, then read; the answer starts below it; no fold mid-turn (Leo 11-21).",
    owner: own.sim,
    harness: "sim",
    make: turn("se-15", "a steer mid-reply", (b) => {
      msg(b, P1, "m1");
      b.steerPrompt("Also check the second caller.");
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-16",
    axis: "stream",
    title: "Steer sent during a tool call",
    expected: "The call stays live and in place; the steer waits under it; nothing folds before turn_result.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-16", "a steer during a call", (b) => {
      b.tool("bun test", { open: true });
      b.steerPrompt("Skip the slow ones.", { read: false });
      b.toolEnd("call-1", { ms: 2_000 });
      b.record("mux", "steer_read", { promptId: "steer-1" }, 100, "steer_read");
      msg(b, P2, "m1");
      b.turnEnd();
    }),
  },
  {
    id: "SE-17",
    axis: "stream",
    title: "Queued message starts the next turn the moment one ends",
    expected:
      "The queued prompt leaves the composer queue and opens a new turn at the turn gap; the old turn folds once; no placeholder left between.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-17", "a queued prompt right after turn end", (b) => {
      msg(b, P1, "m1");
      b.turnEnd();
      b.prompt("Now the second test.", 0);
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-18",
    axis: "stream",
    title: "Hook re-prompt (Stop hook feedback) mid-turn",
    expected:
      "[taste] The hook's feedback draws as a quiet notice line between the two replies, so a repeated answer reads as a response to it, not a duplicate (Leo 08:02 on 1157).",
    owner: own.split,
    harness: "sim",
    // What Leo saw (1157): Claude Code's Stop hook blocks the stop inside the harness, and the agent's next message
    // repeats its last paragraph. acpmux now records the hook's feedback (claude_stdio `stop_hook_feedback`), and
    // the pane draws it as one quiet "hook" line between the two replies.
    make: turn("se-18", "a Stop hook re-prompts inside the harness and the agent repeats itself", (b) => {
      msg(b, P1, "m1");
      b.stopHook("[~/.claude/hooks/check.sh]: 2 tests still fail.", 2_000);
      msg(b, P1, "m2", { after: 2_000 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-19",
    axis: "stream",
    title: "Background task ends after the turn; agent wakes",
    expected: "A background turn draws under its own line; the earlier turn's fold does not reopen or move.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS["background-task"],
  },
  {
    id: "SE-20",
    axis: "stream",
    title: "Compaction mid-turn",
    expected: "One compaction line, live then settled in place; nothing above it moves; no fold before turn end.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS.compaction,
  },
  {
    id: "SE-21",
    axis: "stream",
    title: "Model switch mid-chat",
    expected: "No transcript row moves; at most a one-line note at the boundary.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-21", "the model changes between turns", (b) => {
      msg(b, P1, "m1");
      b.turnEnd();
      b.modelSwitch("opus");
      b.prompt("Continue.");
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-22",
    axis: "stream",
    title: "Another agent's notice opens a turn",
    expected: "The notice line stands the block gap under the last turn; Working for stands the head gap under it.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS["incoming-notice-turn"],
  },
  {
    id: "SE-23",
    axis: "stream",
    title: "Another agent's message opens a turn",
    expected: "As SE-22, for a message.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS["incoming-message-turn"],
  },
  {
    id: "SE-24",
    axis: "stream",
    title: "Plan updates",
    expected: "One plan row, updated in place on each update; no new rows; it does not split the reply around it.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-24", "a plan updated three times", (b) => {
      b.planUpdate([{ content: "Read" }, { content: "Fix" }]);
      msg(b, P1, "m1");
      b.planUpdate([
        { content: "Read", status: "completed" },
        { content: "Fix", status: "in_progress" },
      ]);
      b.tool("bun test", { ms: 500 });
      b.planUpdate([
        { content: "Read", status: "completed" },
        { content: "Fix", status: "completed" },
      ]);
      msg(b, P2, "m2");
      b.turnEnd();
    }),
  },
  {
    id: "SE-25",
    axis: "stream",
    title: "Harness retry supersedes a message",
    expected: "The superseded text goes; the retried text draws once (never both, never a duplicate paragraph).",
    owner: own.split,
    harness: "sim",
    make: turn(
      "se-25",
      "a retried message",
      (b) => {
        msg(b, P1, "m1");
        b.superseded("m1", "m2");
        msg(b, P1, "m2");
        b.turnEnd();
      },
      "codex",
    ),
  },
  {
    id: "SE-26",
    axis: "stream",
    title: "start-record-late: the turn's start arrives after its end",
    expected: "An ended turn draws no placeholder rows (no empty 16 px typing row under the footer).",
    owner: own.inbox,
    harness: "live",
    live: {
      records: turn("se-26", "turn_started overtaken by the turn's end", (b) => {
        msg(b, P1, "m1");
        b.turnEnd();
      }),
      steps: (events) => {
        const start = events.findIndex((event) => event.kind === "turn_started");
        const end = events.findIndex((event) => event.kind === "turn_result");
        return [{ push: start }, { swap: [start, end] }, { push: events.length }];
      },
    },
  },
  {
    id: "SE-27",
    axis: "stream",
    title: "Host notice mid-reply",
    expected: "The notice line draws below the reply; the reply's later words stay in the same bubble above it.",
    owner: own.sim,
    harness: "sim",
    make: turn("se-27", "a host notice mid-reply", (b) => {
      msg(b, P1.slice(0, 60), "m1");
      b.hostNotice("cmux updated in the background.");
      msg(b, P1.slice(60), "m1", { after: 200 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-28",
    axis: "stream",
    title: "Long turn: rounds of text and calls with a long wait",
    expected: "Runs close only under the next paragraph or at turn end; nothing else folds mid-turn.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS["long-turn-messages"],
  },
  {
    // Found by the integrity checker in Leo's own chat (session b0e9114e, seq 5244663-5244700): a reply the agent
    // wrote on its own (a background turn) streamed "**GUI paths:", acpmux ended the background turn (reason
    // prompt) when Leo's message arrived, and the rest of the same message ("** includes forking...") drew as a
    // second bubble under his message, cut inside the bold.
    id: "SE-29",
    axis: "stream",
    title: "The person writes while a reply the agent started on its own is mid-sentence",
    expected:
      "The rest of that message joins its bubble above the person's message (one message, one bubble); the person's message and its answer follow it; no span cut.",
    owner: own.split,
    harness: "sim",
    make: () => {
      const b = sim("se-29", "a background turn's reply is cut by the person's prompt");
      b.prompt("Start the fork tests.");
      b.say("Started.", { messageId: "m0", segment: "turn-1.1.1" });
      b.turnEnd();
      b.record("mux", "background_turn", { id: "bg-1", state: "started", trigger: "system" }, 5_000);
      b.record("mux", "status", { status: "running" }, 10, "status running");
      const cut = BOLD.indexOf("paths:") + 6;
      b.say(BOLD.slice(0, cut), { messageId: "m1", segment: "-.bg.1" });
      b.record("mux", "background_turn", { id: "bg-1", state: "ended", reason: "prompt", trigger: "system" }, 20);
      b.prompt("Also check Codex.", 5);
      b.say(BOLD.slice(cut), { messageId: "m1", segment: "turn-2.bg.1", after: 20 });
      b.say(P2, { messageId: "m2", segment: "turn-2.bg.2", after: 12_000 });
      return b.turnEnd().build();
    },
  },
  {
    // Leo, 2026-11-22 09:53Z: "see this is a weird case where there's like... a tool call in between. but it looks
    // like there's "extra" spacing here. and my message presumably went... i dont know. the ordering here is really
    // funky. i steered, you already had something you wanted to send/do, then you did another thing?"
    id: "SE-30",
    axis: "stream",
    title: "Steer after text, before a send (Sent to) tool call, then more text",
    expected:
      "Text written before the steer stays above it, then the steer, then the send and the reply, in that order.",
    owner: own.sim,
    harness: "sim",
    make: () => {
      const b = sim("se-30", "a steer lands after the turn's first text, then a send, then the reply");
      b.prompt("Which of the taste calls should ship as default?");
      b.tool("gh pr list --search taste", { ms: 2_000 });
      b.say("Nothing has changed for you yet.", { messageId: "m1", segment: "turn-1.1.1" });
      b.steerPrompt("the taste ones i agree with all actually but 50020 prob dont do as default", { after: 400 });
      b.tool("acpmux send beyer-themes 'Leo answered the taste calls: ship the recommended versions.'", { ms: 600 });
      b.say(
        "Will do. The palette, failure card, empty states and worked-turn summary each ship your recommended version.",
        {
          messageId: "m2",
          segment: "turn-1.2.1",
          after: 800,
        },
      );
      return b.turnEnd().build();
    },
  },
  {
    // The same 09:53Z capture. Replayed from Leo's chat (b0e9114e seq 5330115-5330880), the model is clean: it draws
    // the send as `subagents-5330554` between the two replies (gap 16, outside the closed Worked for). The pane hides
    // that row while Worked for is closed and keeps its space, so the gap is a drawn-pixels bug the model cannot see.
    id: "SE-31",
    axis: "stream",
    title: "A Sent to row in a turn whose Worked for is closed",
    expected:
      "A row the closed fold hides takes no space: no blank gap between the replies. Sent to folds into the turn's activity (ST-02) and shows with it.",
    owner: own.received,
    harness: "elsewhere",
    heldBy:
      "lane/chat-received-as-activity (ST-02) browser gallery case; replay: chat-sim --replay <b0e9114e> --from 5330100 --to 5330880",
  },
  // Leo, 2026-11-22 08:25Z: "ok, well. this happened again. you need to help decide what goes on in this case and
  // perfect it." A pause inside a message is never a boundary; each case pauses inside `**bold**` (or `code`) and
  // then something that is not a step of the agent's lands, and the message must stay one bubble, its span whole,
  // no fold inside its text.
  {
    id: "SE-40",
    axis: "stream",
    title: "Pause (5 s, then 20 s) inside **bold** and inside `code`",
    expected:
      "One bubble; both spans close in it; no Worked for or fold between the halves; the live line keeps Working for.",
    owner: own.split,
    harness: "sim",
    make: turn("se-40", "5 s inside bold, 20 s inside code", (b) => {
      const text = `${BOLD} Run \`bun test api --filter retry\` to see it.`;
      const bold = text.indexOf("paths:") + 3;
      const code = text.indexOf("--filter");
      b.say(text.slice(0, bold), { messageId: "m1", segment: "m1.1.1" });
      b.say(text.slice(bold, code), { messageId: "m1", segment: "m1.1.1", after: 5_000 });
      b.say(text.slice(code), { messageId: "m1", segment: "m1.1.1", after: 20_000 });
      b.turnEnd();
    }),
  },
  {
    id: "SE-41",
    axis: "stream",
    title: "Pause inside **bold**, then the socket drops and reconnects",
    expected: "The reply resumes in the same bubble; the bold span closes in it; nothing is drawn twice.",
    owner: own.split,
    harness: "live",
    live: {
      records: turn("se-41", "a pause inside bold and a reconnect", (b) => {
        msg(b, BOLD, "m1", { split: [BOLD.indexOf("paths:") + 3], pauseAt: 1, pauseMs: 12_000 });
        b.turnEnd();
      }),
      steps: (events) => {
        const cut = events.findIndex((event) => event.kind === "agent_message_chunk") + 1;
        return [{ push: cut }, { advance: 6_000 }, { drop: true }, { advance: 6_000 }, { push: events.length }];
      },
    },
  },
  {
    id: "SE-42",
    axis: "stream",
    title:
      "Pause inside **bold** in a background turn; it ends and a queued prompt starts mid-message (false turn end)",
    expected:
      "The rest of the message joins its bubble above the prompt (acpmux keeps its segment across the turn change); the span closes in it; the prompt and its answer follow.",
    owner: own.split,
    harness: "sim",
    make: () => {
      const b = sim("se-42", "a queued prompt ends a background turn inside bold, after a pause");
      b.prompt("Start the fork tests.");
      b.say("Started.", { messageId: "m0", segment: "turn-1.1.1" });
      b.turnEnd();
      b.record("mux", "background_turn", { id: "bg-1", state: "started", trigger: "task_notification" }, 5_000);
      const cut = BOLD.indexOf("paths:") + 3;
      b.say(BOLD.slice(0, cut), { messageId: "m1", segment: "-.bg.1" });
      b.wait(9_000);
      b.record(
        "mux",
        "background_turn",
        { id: "bg-1", state: "ended", reason: "prompt", trigger: "task_notification" },
        20,
      );
      b.prompt("Also check Codex.", 5);
      // acpmux keeps one message's segment across the turn change (hub/stream.rs `before_agent_update`).
      b.say(BOLD.slice(cut), { messageId: "m1", segment: "-.bg.1", after: 20 });
      b.say(P2, { messageId: "m2", segment: "turn-2.bg.1", after: 2_000 });
      return b.turnEnd().build();
    },
  },
  {
    id: "SE-43",
    axis: "stream",
    title: "Pause inside **bold**, then a background task's notification lands mid-message",
    expected:
      "The task's line draws below the reply; the reply's rest stays in its bubble above it; the span closes in it.",
    owner: own.split,
    harness: "sim",
    make: turn("se-43", "a background shell ends inside bold, after a pause", (b) => {
      b.background("bun run watch", { ms: 1 });
      const cut = BOLD.indexOf("paths:") + 3;
      b.say(BOLD.slice(0, cut), { messageId: "m1", segment: "m1.1.1" });
      b.wait(8_000);
      b.backgroundEnds();
      b.say(BOLD.slice(cut), { messageId: "m1", segment: "m1.1.1", after: 200 });
      b.turnEnd();
    }),
  },
  {
    // Leo's 1157: a subagent the pane had not seen sends its first records between two paragraphs of the session's
    // own reply. Its new group row ended the reply's row, so the rest opened a second row (and a refold drew it again).
    id: "SE-44",
    axis: "stream",
    title: "A new subagent's first records land between two paragraphs of a reply",
    expected:
      "The group draws; the reply stays one bubble with each paragraph once (a subagent is no step of the session's).",
    owner: own.split,
    harness: "sim",
    make: turn("se-44", "a new subagent's group mid-reply", (b) => {
      const agent = `${SIM_SESSION}/toolu_late`;
      b.say(`${P1}\n\n`, { messageId: "m1", segment: "m1.1.1" });
      b.record(
        "in",
        "agent_thought_chunk",
        {
          jsonrpc: "2.0",
          method: "session/update",
          params: {
            _meta: { acpmux: { subagent: agent } },
            sessionId: agent,
            update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Reading the lane log." } },
          },
        },
        300,
        "subagent thought",
      );
      b.record(
        "in",
        "subagent_progress",
        {
          jsonrpc: "2.0",
          method: "session/update",
          params: {
            _meta: {
              acpmux: {
                subagents: [{ id: agent, agentId: "a-late", name: "Late lane", state: "running", background: true }],
              },
            },
            sessionId: SIM_SESSION,
            update: {
              sessionUpdate: "subagent_progress",
              subagentSessionId: agent,
              action: "Read",
              elapsedMs: 900,
              tokens: 80,
              toolUses: 1,
            },
          },
        },
        100,
        "subagent progress",
      );
      b.say(P2, { messageId: "m1", segment: "m1.1.1", after: 6_000 });
      b.turnEnd();
    }),
  },
  // Status and activity rows (Leo 08:29-08:30Z)
  {
    id: "ST-01",
    axis: "status",
    title: "start-record-late placeholder (#49992)",
    expected: "An ended turn draws no placeholder rows.",
    owner: own.inbox,
    harness: "elsewhere",
    heldBy: "webviews/src/agent-session/acpmux/conversation/carriedNoticePlaceholder.test.ts (#49992)",
  },
  {
    id: "ST-02",
    axis: "status",
    title: "Received and Sent-to rows mid-turn (Leo 1159)",
    expected:
      "Received-message and sent-to rows are activity rows: same 22 px rhythm and gap as tool calls, folded into the turn's activity, no extra margin.",
    owner: own.received,
    harness: "elsewhere",
    heldBy: "sim scenario received-sent-as-activity (helper PR)",
  },
  {
    id: "ST-03",
    axis: "status",
    title: "In-progress activity shimmers (Leo 1160)",
    expected:
      "Sending, a helper notification being handled, waiting on a reply: live work in the status spot, shimmering exactly like Thinking.",
    owner: own.shimmer,
    harness: "elsewhere",
    heldBy: "status-label shimmer unit test + gallery (helper PR)",
  },
  {
    id: "ST-04",
    axis: "status",
    title: "One shimmer for every status label",
    expected:
      "Waiting, Sending, Thinking and every other label in the thinking spot use one shimmer; no white special case.",
    owner: own.shimmer,
    harness: "elsewhere",
    heldBy: "status-label shimmer unit test + gallery (helper PR)",
  },
  // Markdown across chunk boundaries
  ...(
    [
      ["MD-01", "Bold split across chunks", "Here **is the bold part** and the rest.", 9],
      [
        "MD-02",
        "Code fence split across chunks, with a pause",
        "Run this:\n\n```sh\nbun test api\n```\n\nThen push.",
        18,
      ],
      ["MD-03", "Table split across chunks", "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nDone.", 21],
      ["MD-04", "List split across chunks", "Steps:\n\n- read the helper\n- fix the loop\n- run the test\n\nDone.", 25],
      ["MD-05", "Link split across chunks", "See [the retry helper](https://example.com/retry.ts) for details.", 30],
      ["MD-06", "Math split across chunks", "The delay is $$d_n = b \\cdot 2^n$$ for retry n.", 20],
    ] as const
  ).map(([id, title, text, cut]): StreamScenario => ({
    id,
    axis: "markdown",
    title,
    expected:
      "One bubble; while streaming the open span renders as its intended style (no raw marks flash); settled, the span is closed in the same bubble.",
    owner: own.split,
    harness: "sim",
    make: turn(id.toLowerCase(), title, (b) => {
      msg(b, text, "m1", { split: [cut], pauseAt: 1, pauseMs: 20_000 });
      b.turnEnd();
    }),
  })),
  // Transport
  {
    id: "TR-01",
    axis: "transport",
    title: "Socket drops mid-reply and reconnects",
    expected:
      "The reply resumes in the same bubble from where it was; nothing redraws above; the reconnect line shows only past its budget.",
    owner: own.split,
    harness: "live",
    live: {
      records: turn("tr-01", "a reconnect mid-reply", (b) => {
        msg(b, `${P1} ${P2}`, "m1", { chunks: 8 });
        b.turnEnd();
      }),
      steps: (events) => {
        const mid = events.findIndex((event) => event.kind === "agent_message_chunk") + 3;
        return [{ push: mid }, { drop: true }, { advance: 5_000 }, { push: events.length }];
      },
    },
  },
  {
    id: "TR-02",
    axis: "transport",
    title: "A chunk delivered twice",
    expected: "The duplicate is dropped; the text draws once.",
    owner: own.delivery,
    harness: "live",
    live: {
      records: turn("tr-02", "a duplicate chunk", (b) => {
        msg(b, `${P1} ${P2}`, "m1", { chunks: 6 });
        b.turnEnd();
      }),
      steps: (events) => {
        const at = events.findIndex((event) => event.kind === "agent_message_chunk") + 2;
        return [{ push: at + 1 }, { duplicate: at }, { push: events.length }];
      },
    },
  },
  {
    id: "TR-03",
    axis: "transport",
    title: "Two chunks out of order",
    expected: "Once the late chunk arrives the text is in order, one bubble, nothing lost.",
    owner: own.delivery,
    harness: "live",
    live: {
      records: turn("tr-03", "swapped chunks", (b) => {
        msg(b, `${P1} ${P2}`, "m1", { chunks: 6 });
        b.turnEnd();
      }),
      steps: (events) => {
        const at = events.findIndex((event) => event.kind === "agent_message_chunk") + 2;
        return [{ push: at }, { swap: [at, at + 1] }, { push: events.length }];
      },
    },
  },
  {
    id: "TR-04",
    axis: "transport",
    title: "A chunk arrives after turn_result (late)",
    expected: "It takes its place in its reply (the turn is repaired); one bubble; no new turn, no fold reopening.",
    owner: own.delivery,
    harness: "live",
    live: {
      records: turn("tr-04", "a chunk overtaken by the turn's end", (b) => {
        msg(b, `${P1} ${P2}`, "m1", { chunks: 6 });
        b.turnEnd();
      }),
      steps: (events) => {
        const last = events.map((event) => event.kind).lastIndexOf("agent_message_chunk");
        return [{ push: last }, { swap: [last, events.length - 1] }, { advance: 30_000 }];
      },
    },
  },
  {
    id: "TR-05",
    axis: "transport",
    title: "Daemon restart mid-reply (segment numbering restarts)",
    expected:
      "The same message (same messageId) stays one bubble across the restart; the turn is adopted, not ended; no Worked for between halves.",
    owner: own.split,
    harness: "live",
    live: {
      records: turn("tr-05", "acpmux restarts mid-reply", (b) => {
        b.say(BOLD.slice(0, 40), { messageId: "m1", segment: "turn-1.1.1" });
        b.say(BOLD.slice(40), { messageId: "m1", segment: "turn-1.2.1", after: 3_000 });
        b.turnEnd();
      }),
      steps: (events) => {
        const restart = events.findIndex(
          (event) => event.kind === "agent_message_chunk" && event.msg.params._meta?.acpmux?.segment === "turn-1.2.1",
        );
        return [{ push: restart }, { drop: true }, { advance: 3_000 }, { push: events.length }];
      },
    },
  },
  {
    id: "TR-06",
    axis: "transport",
    title: "Session resume: close the pane and open it again",
    expected: "The reopened chat draws the same rows, in place, at once; never blank; no fold motion replays.",
    owner: own.blank,
    harness: "live",
    live: {
      records: turn("tr-06", "reopen after a finished turn", (b) => {
        msg(b, P1, "m1");
        b.tool("bun test", { ms: 500 });
        msg(b, P2, "m2");
        b.turnEnd();
      }),
      steps: (events) => [{ push: events.length }, { reopen: true }],
    },
  },
  {
    id: "TR-07",
    axis: "transport",
    title: "Replay equals live; lost frames are read back at turn end",
    expected: "Any delivery (lost, swapped, duplicated, dropped) converges to the in-order rows once the turn ends.",
    owner: own.delivery,
    harness: "elsewhere",
    heldBy: "webviews/test/transcript-delivery-property.test.ts (all faults together still diverge: cmuxterm-hq#8950)",
  },
  {
    id: "TR-08",
    axis: "transport",
    title: "Fork",
    expected: "The fork opens on the kept tail, drawn at once; the source chat does not move.",
    owner: own.sim,
    harness: "elsewhere",
    heldBy: "webviews/test/agent-pane-fork-kept-tail.test.ts",
  },
  // View state
  {
    id: "VS-01",
    axis: "view",
    title: "Unfocused, then refocused (since you were here)",
    expected:
      "The marker sits at the first record the reader had not seen when they left; the reader's own latest message is never 'new'; no layout shift when it appears or fades.",
    owner: own.since,
    harness: "elsewhere",
    heldBy: "webviews/test/agent-pane-since-jump-tab-row.test.ts (+ since PR tests)",
  },
  {
    id: "VS-02",
    axis: "view",
    title: "Scrolled to the bottom while streaming",
    expected: "The view follows smoothly (no jolts); folds above the fold line do not move the bottom.",
    owner: own.follow,
    harness: "elsewhere",
    heldBy: "#49596 measured arms; chat-sim-browser b-mid-turn-shrink",
  },
  {
    id: "VS-03",
    axis: "view",
    title: "Scrolled up while a turn runs and ends",
    expected: "What the reader looks at does not move: anchored by (rowId, offset); folds below the viewport are held.",
    owner: own.sim,
    harness: "sim",
    make: SCENARIOS["reader-scroll"],
  },
  {
    id: "VS-04",
    axis: "view",
    title: "Pane resize",
    expected: "Rows reflow; the anchored row keeps its offset; no flash.",
    owner: own.shift,
    harness: "elsewhere",
    heldBy: "lane/agent-chat-layout-watch (#45741) layout watch",
  },
  {
    id: "VS-05",
    axis: "view",
    title: "Tab switch / unloaded tab / tab moved to another pane",
    expected: "The pane keeps its frame; no re-render flash; the original pane does not flicker.",
    owner: own.blank,
    harness: "elsewhere",
    heldBy: "#47553 chat-tab-switch-keeps-frame",
  },
  {
    id: "VS-06",
    axis: "view",
    title: "Window hidden, then shown",
    expected: "On show, the settled state draws at once; no queued animations replay (no fade-in from the bottom).",
    owner: own.fold,
    harness: "elsewhere",
    heldBy: "design/chat-fold-motion.md (reduced motion when hidden)",
  },
  {
    id: "VS-07",
    axis: "view",
    title: "Theme change",
    expected: "Only colours change; no row moves.",
    owner: own.shift,
    harness: "elsewhere",
    heldBy: "theme gallery screenshots",
  },
  {
    id: "VS-08",
    axis: "view",
    title: "Renderer restart / reload",
    expected: "Never blank: the retained snapshot draws in place at once, then live records continue.",
    owner: own.blank,
    harness: "elsewhere",
    heldBy: "webviews/test/agent-pane-restore-long-turn.test.ts; retainedSnapshot",
  },
  {
    id: "VS-09",
    axis: "view",
    title: "Huge history (10k+ rows)",
    expected: "Each step costs about the same at any length; nothing folds early.",
    owner: own.sim,
    harness: "elsewhere",
    heldBy: "webviews/test/chat-sim.test.ts long run",
  },
  {
    id: "VS-10",
    axis: "view",
    title: "Images and attachments",
    expected: "Drawn at their stored size from the first frame; no reshape when they load.",
    owner: own.shift,
    harness: "elsewhere",
    heldBy: "cmuxterm-hq docs/handbook/media-without-stored-size.md",
  },
  {
    id: "VS-11",
    axis: "view",
    title: "Paste into the composer",
    expected: "The caret is at the end of the pasted text in the same frame as the attachment preview.",
    owner: own.composer,
    harness: "elsewhere",
    heldBy: "composer caret tests (unowned for paste: routed)",
  },
  {
    id: "VS-12",
    axis: "view",
    title: "Pane loads (open, restart, update)",
    expected: "No flash, no expand-then-collapse of tool calls: the first frame is the settled one.",
    owner: own.shift,
    harness: "elsewhere",
    heldBy: "#45741 layout watch; #49964 visible-first-transcript",
  },
  {
    id: "VS-13",
    axis: "view",
    title: "Turn finishes: action icons and the final reply",
    expected: "Copy/Fork/Timeline appear the frame the turn ends; the reply does not fade in from the bottom.",
    owner: own.icons,
    harness: "elsewhere",
    heldBy: "#49963 turn-action-row-pop-in",
  },
  ...timing,
];

export const scenarioById = (id: string) => STREAM_SCENARIOS.find((scenario) => scenario.id === id);
