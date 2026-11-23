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
    b.tool(`rg -n "retry" src/api/part${call}.ts`, { ms: 600 + (call % 3) * 400 });
    if (middleText && call === Math.floor(calls / 2)) b.say(PARAGRAPH, { chunks: 6 });
  }
  return b;
}

export const SCENARIOS: Record<string, () => SimScenario> = {
  basic: () =>
    sim("basic", "One prompt: a thought, commands with text between, a reply, the turn ends.")
      .prompt("The retry test is flaky. Find out why and fix it.")
      .think("Reading the helper first.")
      .tool("sed -n 1,80p src/api/client.ts", { kind: "read" })
      .say(PARAGRAPH)
      .tool("bun test api/client.test.ts", { status: "failed", output: "1 fail" })
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
    b.wait(10_000).incoming("Can you also rebase on main?", { kind: "agent_message", fromName: "coord-deputy" });
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

  // Leo, 2026-11-22 08:29Z (ST-02, his screenshot 1159): "this one seems to have an unnecessary gap due to being a
  // recieved message. these aren't categorized properly under our tool call formatting." Another agent's message
  // opens a turn that sends one and replies; the reader opens its "Worked for" (the message its first entry, then
  // "Sent to"). A notice opens the next turn, which receives a message mid-turn and sends between its calls. The
  // received and "Sent to" rows are activity rows: each stands the gap a tool row stands in its place, every step.
  "received-sent-as-activity": () => {
    const b = sim(
      "received-sent-as-activity",
      "Another agent's message opens a turn that sends one and replies; a notice opens the next, which receives a message mid-turn and sends one.",
    );
    b.prompt("Map all chat stream edge cases with your helper.");
    b.think("Starting the helper.");
    b.tool("acpmux send map-edge-cases 'Map all chat stream edge cases.'", { ms: 500 });
    b.turnEnd();
    b.wait(20_000).incoming("chat-scenarios: no lane of mine holds it; it's yours.", {
      kind: "agent_message",
      fromName: "claude-sr2-coord",
    });
    b.tool("acpmux send map-edge-cases 'claude-sr2-coord says chat-scenarios is ours; carry on.'", { ms: 500 });
    b.say("Got it, thanks. My helper owns chat-scenarios, covering the stream edge cases as well as the oddities.");
    b.turnEnd();
    // 1159: the reader opens that turn's "Worked for": the message that opened it is its first entry, then "Sent to".
    b.reader({ open: "worked-user-12" });
    b.wait(20_000).incoming("Prioritize visible cmux under load finished", {
      kind: "notice",
      fromName: "visible-under-load",
      title: "Prioritize visible cmux under load finished",
    });
    b.tool("acpmux send visible-under-load 'Keep going; send me the numbers.'", { ms: 500 });
    b.tool("rg -n 'under load' docs", { ms: 400 });
    b.message("The numbers: p95 frame 9 ms under load.", { fromName: "visible-under-load" });
    b.tool("acpmux send visible-under-load 'Thanks, land it.'", { ms: 500 });
    b.tool("git status --short", { ms: 300 });
    b.say("Both helpers have their next steps.");
    b.turnEnd();
    return b.reader({ open: "worked-user-24" }).build();
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

  // ---- The map (sim/map.ts): one scenario per way a chat's display has gone wrong, or plausibly can. ----
  // Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note what
  // expected behaviours are for all."

  "stopped-turn": () => {
    const b = sim("stopped-turn", "The person stops a turn while a command runs, then prompts again.");
    b.prompt("Run the whole suite.");
    b.think("Starting with the slow tests.");
    b.tool("bun test slow/", { ms: 700 });
    b.say("The slow tests pass; running the rest.");
    b.tool("bun test", { open: true });
    b.wait(5_000).stop({ calls: ["call-2"] });
    b.prompt("Only the api tests, please.", 4_000);
    b.tool("bun test api/", { ms: 900 });
    b.say("The api tests pass.");
    return b.turnEnd().build();
  },

  "failed-turn": () => {
    const b = sim("failed-turn", "A turn fails halfway through its work, and the next prompt carries on.");
    b.prompt("Fix the flaky test.");
    workTurn(b, 2, { middleText: false });
    b.say("Two callers left.");
    b.tool("rg -n withRetry src", { open: true });
    b.fail("API Error: 529 overloaded");
    b.prompt("Try again.", 5_000);
    b.tool("rg -n withRetry src", { ms: 500 });
    b.say("Fixed the last two.");
    return b.turnEnd().build();
  },

  "retrying-turn": () => {
    const b = sim("retrying-turn", "The model cannot be reached mid-turn; acpmux retries, then the turn carries on.");
    b.prompt("Summarize the diff.");
    b.think("Reading the diff.");
    b.tool("git diff --stat", { ms: 400 });
    b.say("Three files changed.");
    b.retry();
    b.tool("git diff", { ms: 600 });
    b.say("The change is a rename and two call sites.");
    return b.turnEnd().build();
  },

  "steer-mid-turn": () => {
    const b = sim(
      "steer-mid-turn",
      "The person types twice while the turn runs: between commands, and while a reply streams.",
    );
    b.prompt("Refactor the retry helper.");
    b.think("Reading it first.");
    b.tool("sed -n 1,80p src/api/client.ts", { kind: "read" });
    b.steer("Keep the public signature as it is.");
    b.tool("rg -n withRetry src", { ms: 500 });
    b.say(PARAGRAPH, { chunks: 3 });
    b.steer("And add a test.", { after: 40 });
    b.say(PARAGRAPH, { chunks: 3 });
    b.tool("bun test api/", { ms: 900 });
    b.say("Refactored, signature kept, test added.");
    return b.turnEnd().build();
  },

  "queued-prompt": () => {
    const b = sim("queued-prompt", "A prompt sent while the turn runs waits in the queue, then runs as the next turn.");
    b.prompt("Run the migration.");
    workTurn(b, 2, { middleText: false });
    b.record("mux", "queued", { promptId: "prompt-2", text: "Then run the tests.", client: "pane" }, 300);
    b.tool("bun run migrate", { ms: 2_000 });
    b.say("Migrated.");
    b.turnEnd();
    b.record("mux", "dequeued", { promptId: "prompt-2" }, 50);
    b.prompt("Then run the tests.", 50);
    b.tool("bun test", { ms: 900 });
    b.say("Green.");
    return b.turnEnd().build();
  },

  "permission-wait": () => {
    const b = sim(
      "permission-wait",
      "A command waits on the person's Allow for a while, runs, and a second one is denied.",
    );
    b.prompt("Clean the build folder and push.");
    b.think("Removing the old build.");
    b.tool("rm -rf build", { open: true });
    b.permission("call-1", { ms: 30_000 });
    b.toolEnd("call-1");
    b.say("Cleaned; pushing.");
    b.tool("git push --force", { open: true });
    b.permission("call-2", { allow: false });
    b.toolEnd("call-2", { status: "failed", output: "The person denied this." });
    b.say("I did not push: you denied the force push.");
    return b.turnEnd().build();
  },

  "plan-checklist": () => {
    const b = sim(
      "plan-checklist",
      "A turn writes a checklist, ticks it off between commands, and the next turn clears it.",
    );
    b.prompt("Migrate the three services.");
    b.plan([
      ["Migrate auth", "in_progress"],
      ["Migrate billing", "pending"],
      ["Migrate mail", "pending"],
    ]);
    b.tool("bun run migrate auth", { ms: 800 });
    b.plan([
      ["Migrate auth", "completed"],
      ["Migrate billing", "in_progress"],
      ["Migrate mail", "pending"],
    ]);
    b.say("Auth is done.");
    b.tool("bun run migrate billing", { ms: 800 });
    b.tool("bun run migrate mail", { ms: 800 });
    b.plan([
      ["Migrate auth", "completed"],
      ["Migrate billing", "completed"],
      ["Migrate mail", "completed"],
    ]);
    b.say("All three migrated.");
    b.turnEnd();
    b.prompt("Now the docs.", 5_000);
    b.plan([]);
    b.tool("rg -n migrate docs", { ms: 500 });
    b.say("Docs updated.");
    return b.turnEnd().build();
  },

  "long-output": () => {
    const b = sim(
      "long-output",
      "A command prints thousands of lines, and the reply is fifty paragraphs with a table and code.",
    );
    b.prompt("Dump the log and explain it.");
    b.tool("cat build.log", {
      ms: 1_500,
      output: Array.from({ length: 4_000 }, (_, line) => `line ${line}: ${"x".repeat(line % 180)}`).join("\n"),
    });
    b.say(
      Array.from({ length: 50 }, (_, part) =>
        part % 10 === 4
          ? "| step | ms |\n| --- | --- |\n| link | 900 |\n| sign | 12000 |\n"
          : part % 10 === 7
            ? "```sh\nbun run build --profile\n```\n"
            : `${PARAGRAPH}\n`,
      ).join("\n"),
      { chunks: 120, chunkMs: 30 },
    );
    b.tool("rg -c error build.log", { ms: 300 });
    b.say("The build spends its time signing.");
    return b.turnEnd().build();
  },

  "parallel-tools": () => {
    const b = sim(
      "parallel-tools",
      "Four commands start together and end out of order, one failing, while text streams.",
    );
    b.prompt("Check all four packages.");
    b.think("Running them at once.");
    for (const name of ["api", "web", "cli", "docs"]) b.tool(`bun test ${name}/`, { open: true }, 20);
    b.toolEnd("call-3", { ms: 400 });
    b.toolEnd("call-1", { ms: 700 });
    b.toolEnd("call-4", { ms: 200, status: "failed", output: "2 fail" });
    b.toolEnd("call-2", { ms: 2_500 });
    b.say("Three pass; docs has two failures.");
    b.tool("bun test docs/ --only-failures", { ms: 800 });
    b.say("Both failures are stale snapshots.");
    return b.turnEnd().build();
  },

  "thought-only-turn": () => {
    const b = sim(
      "thought-only-turn",
      "A turn that only thinks, one that only runs a command, and one that replies with nothing else.",
    );
    b.prompt("Think about whether we need the cache.");
    b.think("The cache saves one read per request, and the read is already fast.", { chunks: 5 });
    b.turnEnd();
    b.prompt("Check the build.", 4_000);
    b.tool("bun run build", { ms: 900 });
    b.turnEnd();
    b.prompt("So do we need it?", 4_000);
    b.say("No.");
    return b.turnEnd().build();
  },

  "empty-turn": () => {
    const b = sim("empty-turn", "A turn that ends with nothing drawn, between two ordinary turns.");
    b.prompt("Fix the flaky test.");
    workTurn(b, 2);
    b.say("Done.");
    b.turnEnd();
    b.prompt("ok", 4_000);
    b.turnEnd("completed", 800);
    b.prompt("Now rebase.", 4_000);
    b.tool("git rebase origin/main", { ms: 900 });
    b.say("Rebased.");
    return b.turnEnd().build();
  },

  "incoming-burst": () => {
    const b = sim(
      "incoming-burst",
      "Five notices and messages from other agents in a row, each answered with one line or one command.",
    );
    b.prompt("Coordinate the three lanes.");
    workTurn(b, 2, { middleText: false });
    b.say("All three have their tasks.");
    b.turnEnd();
    for (let index = 0; index < 5; index += 1) {
      b.incoming(
        `lane-${index}: step ${index} finished`,
        { kind: index % 2 ? "agent_message" : "notice", fromName: `lane-${index}` },
        index === 0 ? 20_000 : 600,
      );
      if (index % 2) b.say(`Noted, lane-${index}.`);
      else if (index === 2) b.tool("git fetch origin", { ms: 400 });
      // Not played: an incoming line the agent answers with nothing, with another right under it. Chrome
      // draws the second flush under the first (map.ts, `silent-received-flush`).
      else b.say("Seen.");
      b.turnEnd();
    }
    b.prompt("Where are we?", 8_000);
    b.say("All five steps are in.");
    return b.turnEnd().build();
  },

  "compaction-at-end": () => {
    const b = sim(
      "compaction-at-end",
      "A compaction is still running when the turn ends, and the next turn opens on its summary.",
    );
    b.prompt("Keep going with the migration.");
    workTurn(b, 3, { middleText: false });
    b.say("Halfway.");
    b.record(
      "in",
      "compaction",
      {
        jsonrpc: "2.0",
        method: "session/update",
        params: { sessionId: "agent-1", update: { sessionUpdate: "compaction", state: "started" } },
      },
      300,
      "compaction started",
    );
    b.turnEnd();
    b.prompt("Continue.", 6_000);
    b.record(
      "in",
      "compaction",
      {
        jsonrpc: "2.0",
        method: "session/update",
        params: { sessionId: "agent-1", update: { sessionUpdate: "compaction", state: "completed" } },
      },
      300,
      "compaction completed",
    );
    workTurn(b, 2);
    b.say("Migration done.");
    return b.turnEnd().build();
  },

  "lost-result": () => {
    const b = sim(
      "lost-result",
      "A command's result never arrives: the turn ends with the call still open, and the next turn runs.",
    );
    b.prompt("Deploy it.");
    b.think("Deploying.");
    b.tool("bun run deploy", { open: true });
    b.wait(10_000).say("Deployed.");
    b.turnEnd();
    b.prompt("And the docs?", 5_000);
    b.tool("bun run deploy:docs", { ms: 900 });
    b.say("Docs deployed.");
    b.turnEnd();
    // The reader opens the first turn: what its command reads as now.
    return b.reader({ open: "worked-user-1" }).build();
  },

  "failed-helpers": () => {
    const b = sim("failed-helpers", "A subagent fails and a background shell exits non-zero after its turn ended.");
    b.prompt("Scan the logs and start the server.");
    b.tool("Scan the last 50 CI logs", {
      kind: "think",
      tool: "Agent",
      ms: 3_000,
      status: "failed",
      output: "The subagent hit its limit.",
    });
    b.background("bun run dev", { ms: 15_000 });
    b.say("The scan failed; the server is starting.");
    b.turnEnd();
    b.wait(15_000);
    b.record(
      "in",
      "background_task_update",
      {
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "background_task_update",
            taskId: "bg-call-2",
            toolCallId: "call-2",
            command: "bun run dev",
            description: "bun run dev",
            origin: "bash",
            state: "failed",
            exitCode: 1,
          },
        },
      },
      0,
      "background failed",
    );
    b.prompt("Did the server start?", 5_000);
    b.say("No: it exited with status 1.");
    return b.turnEnd().build();
  },

  "reader-opens-mid-turn": () => {
    const b = sim(
      "reader-opens-mid-turn",
      "The reader opens the finished turn's Worked for while the next turn runs, and it stays open.",
    );
    b.prompt("Fix the flaky test.");
    workTurn(b, 3);
    b.say("Done.");
    b.turnEnd();
    b.prompt("Now the lint.", 4_000);
    b.tool("bun run lint", { ms: 900 });
    b.reader({ open: "worked-user-1" });
    workTurn(b, 2, { middleText: false });
    b.say("Lint is clean.");
    return b.turnEnd().build();
  },

  "codex-turn": () => {
    const b = sim("codex-turn", "A Codex turn: commentary between commands, then the final answer.", "codex");
    b.prompt("Fix the flaky test.");
    b.say("I'll read the helper first.");
    b.tool("sed -n 1,80p src/api/client.ts", { kind: "read" });
    b.say("The loop allows one attempt too many.");
    b.tool("bun test api/", { ms: 900 });
    b.tool("git diff --stat", { ms: 300 });
    b.say("Fixed: the loop now makes exactly `attempts` calls. " + PARAGRAPH, { chunks: 6 });
    return b.turnEnd().build();
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
      b.tool(`run step ${turn}.${call}`, { ms: 500 + ((turn * 7 + call * 13) % 9) * 700 });
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
