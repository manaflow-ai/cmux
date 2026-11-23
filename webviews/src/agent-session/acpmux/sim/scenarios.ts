// l10n-allow-file: simulated chat fixtures for the chat simulator, not shipped UI.
// The chat simulator's named scenarios (sim/README.md). Each is a chat no agent ran: records on a
// virtual clock, built with script.ts. `longRun` makes a chat as long as asked (10k+ rows, hours).
import { sim, type SimBuilder, type SimScenario } from "./script";

const PARAGRAPH =
  "I read the retry helper and the test that covers it. The loop allows one attempt too many, and the first retry waits zero milliseconds, so the test that counts calls sees four instead of three. ";

/** A finished turn of `calls` commands with text between some of them. */
function workTurn(b: SimBuilder, calls: number, { thoughts = true, middleText = true } = {}): SimBuilder {
  for (let call = 0; call < calls; call += 1) {
    if (thoughts) b.think(`Checking step ${call + 1} before running it.`);
    b.tool(`rg -n "retry" src/api/part${call}.ts`, {
      ms: 600 + (call % 3) * 400,
    });
    if (middleText && call === Math.floor(calls / 2)) b.say(PARAGRAPH, { chunks: 6 });
  }
  return b;
}

export const SCENARIOS: Record<string, () => SimScenario> = {
  // Leo, 2026-11-22: "this is also a crazy situation for the folding and whatever the steer and you think and
  // messages and situations come in and subagents come in and out", "i am still seeing flickers and flashes of
  // bullshit. sub-second in and out bullshit." A coordinator's busy turn: thoughts between quick commands,
  // steers that land mid-turn, subagents that start and finish, another agent's message, a turn that settles
  // and a prompt sent right after it.
  churn: () => {
    const b = sim(
      "churn",
      "A busy coordinator turn: quick commands, thoughts, steers, subagents in and out, then a prompt right after the turn settles.",
    );
    b.prompt("Find out why the land keeps waiting on broker calls.");
    b.think("Reading the land's log first.", { chunks: 2 });
    b.tool("Inspect stuck wt reclaim process", { ms: 400 });
    b.think("The stdout pipe is full at 16384 bytes.", { chunks: 2 });
    b.tool("List open files of the stuck process", { ms: 300 });
    b.say("Its stdout pipe holds 16384 bytes, which looks like a full buffer. I'll find who holds the read end.", {
      chunks: 3,
    });
    b.tool("Find the reader end of the pipe", { ms: 350 });
    b.subagent("Fix doubled handbook row on hq main", {
      ms: 2_500,
      report: "finished",
    });
    b.steer("not sure why there are 595 held for you", {
      after: 300,
      readAfter: 1_200,
    });
    b.tool("Inspect tail and parent processes", { ms: 300 });
    b.think("I'm puzzled why tail -3 seems alive but isn't reading.", {
      chunks: 2,
    });
    b.say("Leo's question first: why 595 messages are held for me.", {
      chunks: 2,
    });
    for (let call = 0; call < 3; call += 1) b.tool(`Show acpmux inbox step ${call + 1}`, { ms: 250 + call * 150 }, 150);
    b.think("I'm looking for where the held count in the chat UI comes from.", {
      chunks: 2,
    });
    b.subagent("Summarize held inbox messages by sender", {
      ms: 1_800,
      report: "finished",
    });
    b.steer("and the pill keeps popping in and out", {
      after: 200,
      readAfter: 800,
    });
    b.steer("remove it", { after: 400, readAfter: 600 });
    b.tool("Show my acpmux session info", { ms: 300 });
    b.think("Both steers ask for the same thing.", { chunks: 2 });
    for (let call = 0; call < 4; call += 1) b.tool(`rg -n held src/part${call}.ts`, { ms: 200 + call * 100 }, 120);
    b.say("The held count is the inbox's unread total; I'll take the pill out.", { chunks: 3 });
    b.turnEnd();
    b.wait(4_000);
    // The prompt sent right after the turn settled (Leo, 21:41Z: "it was as if briefliy the worked for
    // disappeared and then reappeared").
    b.prompt("these should just be gone", 0);
    b.think("Sorting out what Leo asked for.", { chunks: 2 });
    b.tool("Find lanes owning update pill and chat folding", { ms: 600 });
    b.say("Two lanes own these; I'll forward it.", { chunks: 2 });
    return b.turnEnd().build();
  },

  // Leo, 2026-11-22 21:37Z: "when i sent that message it was as if briefliy the worked for disappeared and then
  // reappeared ... accounting for space for the worked for/working heading should always be there anyways". A
  // turn with work settles and folds under its Worked for; a prompt sent after it is answered with a thought and
  // a short reply, no calls.
  "send-after-settle": () => {
    const b = sim(
      "send-after-settle",
      "A turn with work settles; the next prompt is answered at once, with no calls: its heading must hold its place.",
    );
    b.prompt("Find out why the land waits.");
    b.think("Reading the log.", { chunks: 2 });
    b.tool("Inspect the stuck process", { ms: 400 });
    b.tool("List its open files", { ms: 300 });
    b.say("The stdout pipe is full.", { chunks: 2 });
    b.turnEnd();
    b.wait(4_000);
    b.prompt("thanks, now just say done", 0);
    b.think("A short answer.", { chunks: 1 });
    b.say("Done.", { chunks: 1 });
    return b.turnEnd().build();
  },

  basic: () =>
    sim("basic", "One prompt: a thought, commands with text between, a reply, the turn ends.")
      .prompt("The retry test is flaky. Find out why and fix it.")
      .think("Reading the helper first.")
      .tool("sed -n 1,80p src/api/client.ts", { kind: "read" })
      .say(PARAGRAPH)
      .tool("bun test api/client.test.ts", {
        status: "failed",
        output: "1 fail",
      })
      .say("Fixed: the loop now makes exactly `attempts` calls.")
      .turnEnd()
      .build(),

  // Leo, 2026-11-21 (/tmp/cao-leo-shots/4-no-gap-before-working.png): a turn ended on work ("Sent a message, used a
  // tool, received a message"), then another agent's notice started the next turn, and its "Working for 49s"
  // stood flush under the notice, with a rule and "Ran 3 commands" under it.
  "incoming-notice-turn": () => {
    const b = sim(
      "incoming-notice-turn",
      "A turn that ends on work, then another agent's notice starts a turn of commands.",
    );
    b.prompt("Watch the broker and tell the lane when it merges.");
    workTurn(b, 3, { middleText: false });
    b.turnEnd();
    b.wait(30_000).incoming("hq#16160 merged at 23b3c1da6", {
      kind: "notice",
      fromName: "notice-flood-fix",
      title: "hq#16160 merged",
    });
    b.think("I'm checking whether restarting the broker is safe.");
    b.tool("Restart the broker on both hosts", { ms: 3_000 });
    b.think("There's no restart subcommand; reading its help.");
    b.tool("Show broker subcommands");
    b.think("The help says serve restarts itself when the binary changed.");
    b.tool("Read how the broker picks up new code", { open: true });
    b.wait(45_000);
    b.toolEnd("call-6");
    b.say("The broker restarts itself on a new binary; nothing to do.");
    return b.turnEnd().build();
  },

  "incoming-message-turn": () => {
    const b = sim("incoming-message-turn", "A finished turn with a reply, then another agent's message starts a turn.");
    b.prompt("Fix the flaky test.");
    workTurn(b, 2);
    b.say("Done.");
    b.turnEnd();
    b.wait(10_000).incoming("Can you also rebase on main?", {
      kind: "agent_message",
      fromName: "coord-deputy",
    });
    b.tool("git fetch origin && git rebase origin/main", { ms: 2_000 });
    b.say("Rebased; the branch is up to date.");
    return b.turnEnd().build();
  },

  // Leo, 2026-11-21: "the messages and whatever collapsing and stuff, sometimes it does so too soon in the midst of a turn".
  "long-turn-messages": () => {
    const b = sim(
      "long-turn-messages",
      "One long turn: text, runs of commands, more text, a long wait, more runs; folds must wait for the end.",
    );
    b.prompt("Audit every caller of withRetry and fix the ones that double-retry.");
    for (let round = 0; round < 6; round += 1) {
      b.say(`Round ${round + 1}: ${PARAGRAPH}`, { chunks: 5 });
      b.think(`Which callers are left in round ${round + 1}?`);
      for (let call = 0; call < 3; call += 1) b.tool(`rg -n withRetry src/part${round}-${call}`, { ms: 500 });
      if (round === 2) b.wait(20_000);
    }
    b.say("All callers fixed.");
    return b.turnEnd().build();
  },

  "background-task": () => {
    const b = sim(
      "background-task",
      "A turn leaves a shell in the background and ends; the shell ends later and the agent works on its own.",
    );
    b.prompt("Start the dev server and check the page.");
    b.background("bun run dev", { ms: 20_000 });
    b.say("The dev server is starting in the background.");
    b.turnEnd();
    b.wait(20_000).backgroundEnds();
    b.record("mux", "background_turn", { id: "bgturn-1", state: "started", trigger: "task_notification" }, 200);
    b.record("mux", "status", { status: "running" }, 10, "status running");
    b.tool("curl -s localhost:5173 | head", { ms: 400 });
    b.say("The page serves.");
    b.record("mux", "background_turn", { id: "bgturn-1", state: "ended", trigger: "task_notification" }, 200);
    b.record("mux", "status", { status: "ready" }, 10, "status ready");
    return b.build();
  },

  subagent: () => {
    const b = sim("subagent", "A turn starts a subagent, works beside it, and replies after its report.");
    b.prompt("Find every flaky test in the repo.");
    b.say("I'll have a subagent scan the test logs while I read the suite.");
    b.subagent("Scan the last 50 CI logs for flaky tests", { ms: 8_000 });
    b.tool("rg -n 'retry' test/", { ms: 600 });
    b.say("Three tests are flaky; the subagent's list matches mine.");
    return b.turnEnd().build();
  },

  compaction: () => {
    const b = sim("compaction", "A turn compacts its context halfway through its work.");
    b.prompt("Keep going with the migration.");
    workTurn(b, 3, { middleText: false });
    b.compaction();
    workTurn(b, 3);
    b.say("Migration done.");
    return b.turnEnd().build();
  },

  "reader-scroll": () => {
    const b = sim(
      "reader-scroll",
      "The reader scrolls to the top while a turn runs, the turn ends, and they scroll back.",
    );
    for (let turn = 0; turn < 4; turn += 1) {
      b.prompt(`Step ${turn + 1} of the migration.`);
      workTurn(b, 3);
      b.say("Done with this step.");
      b.turnEnd();
    }
    b.prompt("Last step.");
    workTurn(b, 2, { middleText: false });
    b.reader({ scroll: "top" });
    b.tool("bun test", { ms: 2_000 });
    b.say("All green.");
    b.turnEnd();
    b.reader({ scroll: "bottom" }, 1_000);
    return b.build();
  },
};

/// A monstrously long chat: `turns` turns of mixed work (prompts and incoming messages, thoughts,
/// commands, text, a compaction every 25 turns, a background shell every 10), about 12 rows a turn,
/// minutes of virtual time each. `longRun(1000)` is 10k+ rows and many hours of simulated time.
export function longRun(turns: number): SimScenario {
  const b = sim(`long-${turns}`, `${turns} turns of mixed work`);
  for (let turn = 0; turn < turns; turn += 1) {
    if (turn % 7 === 6)
      b.incoming(
        `Lane report ${turn}: merged.`,
        { kind: turn % 2 ? "notice" : "agent_message", fromName: "coord" },
        60_000,
      );
    else b.prompt(`Turn ${turn + 1}: continue with the next part.`, 60_000);
    const calls = 2 + (turn % 5);
    for (let call = 0; call < calls; call += 1) {
      if (call % 2 === 0) b.think(`Planning call ${call + 1}.`, { chunks: 2 });
      b.tool(`run step ${turn}.${call}`, {
        ms: 500 + ((turn * 7 + call * 13) % 9) * 700,
      });
      if (call === 1) b.say(`Progress on turn ${turn + 1}: ${PARAGRAPH}`, { chunks: 3 });
    }
    if (turn % 25 === 24) b.compaction();
    if (turn % 10 === 9) b.background(`watch build ${turn}`, { ms: 30_000 });
    b.say(`Turn ${turn + 1} done.`, { chunks: 2 });
    b.turnEnd();
    b.backgroundEnds();
  }
  return b.build();
}

export const scenarioNames = () => Object.keys(SCENARIOS);
