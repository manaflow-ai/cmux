#!/usr/bin/env bun
import * as readline from "node:readline";
import chalk from "chalk";
import {
  SessionOrchestrator,
  type SessionSpec,
  type Question,
  type MorphSession,
  type SessionFilter,
} from "@cmux/orchestrator";

/**
 * CLI for Micromanaging Claude Code Sessions
 *
 * Usage:
 *   bun run src/index.ts [options]
 *
 * Options:
 *   --user <userId>     Filter sessions by user ID
 *   --team <teamId>     Filter sessions by team ID
 *   --task <taskRunId>  Watch a specific task run
 *   --help              Show help
 *
 * Commands (interactive):
 *   <qN> <answer>       Answer question N
 *   skip <qN>           Skip question N
 *   tell <id> <msg>     Send message to session
 *   status              Show all sessions
 *   quit                Exit
 */

// Parse CLI arguments
function parseArgs(): { filter: SessionFilter; help: boolean } {
  const args = process.argv.slice(2);
  const filter: SessionFilter = {};
  let help = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    if (arg === "--help" || arg === "-h") {
      help = true;
    } else if ((arg === "--user" || arg === "-u") && next) {
      filter.userId = next;
      i++;
    } else if ((arg === "--team" || arg === "-t") && next) {
      filter.teamId = next;
      i++;
    } else if ((arg === "--task") && next) {
      filter.taskRunId = next;
      i++;
    }
  }

  return { filter, help };
}

function printHelp(): void {
  console.log(`
${chalk.bold.cyan("cmux-watch")} - Monitor and interact with Claude Code sessions

${chalk.bold("USAGE:")}
  bun run packages/cli-watch/src/index.ts [OPTIONS]

${chalk.bold("OPTIONS:")}
  --user, -u <userId>   Filter sessions by user ID (from Morph metadata)
  --team, -t <teamId>   Filter sessions by team ID
  --task <taskRunId>    Watch a specific task run
  --help, -h            Show this help

${chalk.bold("INTERACTIVE COMMANDS:")}
  q1 <answer>           Answer pending question 1
  skip q1               Skip pending question 1
  tell <instanceId> <message>
                        Send a message to a session
  status                Show all sessions and questions
  refresh               Force refresh session list
  quit, q               Exit

${chalk.bold("ENVIRONMENT:")}
  MORPH_API_KEY         Required. Morph Cloud API key.

${chalk.bold("EXAMPLES:")}
  # Watch all your sessions
  bun run packages/cli-watch/src/index.ts --user user_abc123

  # Watch a specific team's sessions
  bun run packages/cli-watch/src/index.ts --team team_xyz

  # Watch a specific task
  bun run packages/cli-watch/src/index.ts --task mn7abc123
`);
}

// Global state
let orchestrator: SessionOrchestrator;
const pendingQuestions: Map<string, { session: MorphSession; question: Question }> = new Map();
let questionCounter = 0;

function printHeader(filter: SessionFilter): void {
  console.log(chalk.bold.cyan("\n  CMUX Session Orchestrator"));
  console.log(chalk.gray("  ─".repeat(30)));

  const filterParts: string[] = [];
  if (filter.userId) filterParts.push(`user: ${filter.userId}`);
  if (filter.teamId) filterParts.push(`team: ${filter.teamId}`);
  if (filter.taskRunId) filterParts.push(`task: ${filter.taskRunId}`);

  if (filterParts.length > 0) {
    console.log(chalk.gray(`  Filtering: ${filterParts.join(", ")}`));
  } else {
    console.log(chalk.yellow("  Warning: No filter set. Watching ALL cmux sessions."));
    console.log(chalk.gray("  Use --user, --team, or --task to filter."));
  }
  console.log();
}

function printSessions(): void {
  const sessions = orchestrator.getSessions();

  if (sessions.length === 0) {
    console.log(chalk.yellow("\n  No sessions found matching filter."));
    console.log(chalk.gray("  Waiting for sessions...\n"));
    return;
  }

  console.log(chalk.bold(`\n  Sessions (${sessions.length}):`));

  for (const session of sessions) {
    const spec = orchestrator.getSpec(session.instanceId);
    const statusIcon = session.status === "ready" ? chalk.green("●") : chalk.yellow("○");
    const openQuestions = spec?.questions.filter((q) => q.status === "open").length ?? 0;
    const questionBadge = openQuestions > 0 ? chalk.red(` [${openQuestions} ?]`) : "";

    // Show task run ID if available
    const taskId = session.metadata.taskRunId
      ? chalk.gray(` (${session.metadata.taskRunId.slice(0, 10)}...)`)
      : "";

    console.log(
      `  ${statusIcon} ${chalk.white(session.instanceId)}${taskId}${questionBadge}`
    );

    if (spec?.currentFocus) {
      console.log(chalk.gray(`      Focus: ${spec.currentFocus.slice(0, 60)}`));
    }
  }
  console.log();
}

function printPendingQuestions(): void {
  // Clear and rebuild pending questions
  pendingQuestions.clear();
  questionCounter = 0;

  const sessionsWithQuestions = orchestrator.getSessionsWithQuestions();

  if (sessionsWithQuestions.length === 0) {
    return;
  }

  console.log(chalk.bold.yellow("  Pending Questions:"));

  for (const { session, questions } of sessionsWithQuestions) {
    for (const question of questions) {
      questionCounter++;
      const key = `q${questionCounter}`;
      pendingQuestions.set(key, { session, question });

      const taskId = session.metadata.taskRunId?.slice(0, 10) ?? session.instanceId.slice(0, 12);

      console.log(
        chalk.cyan(`\n  [${key}]`) + chalk.gray(` from ${taskId}...`)
      );
      console.log(chalk.white(`      "${question.question}"`));

      if (question.options && question.options.length > 0) {
        question.options.forEach((opt, i) => {
          console.log(chalk.gray(`        ${i + 1}. ${opt}`));
        });
      }

      if (question.claudeSuggestion) {
        console.log(chalk.blue(`      Suggestion: ${question.claudeSuggestion}`));
      }
    }
  }

  console.log(chalk.gray("\n  Reply with: q1 <your answer>"));
  console.log();
}

async function handleCommand(input: string): Promise<void> {
  const parts = input.trim().split(/\s+/);
  const command = parts[0]?.toLowerCase();

  if (!command) return;

  switch (command) {
    case "status":
    case "s":
      printSessions();
      printPendingQuestions();
      break;

    case "tell": {
      const sessionId = parts[1];
      const message = parts.slice(2).join(" ");
      if (!sessionId || !message) {
        console.log(chalk.red("  Usage: tell <session-id> <message>"));
        break;
      }
      const success = await orchestrator.sendMessage(sessionId, message);
      console.log(success ? chalk.green("  Sent.") : chalk.red("  Failed."));
      break;
    }

    case "skip": {
      const qKey = parts[1];
      if (!qKey) {
        console.log(chalk.red("  Usage: skip <qN>"));
        break;
      }
      const pending = pendingQuestions.get(qKey);
      if (!pending) {
        console.log(chalk.red(`  Question ${qKey} not found.`));
        break;
      }
      await orchestrator.skipQuestion(pending.session.instanceId, pending.question.id);
      pendingQuestions.delete(qKey);
      console.log(chalk.yellow("  Skipped."));
      break;
    }

    case "refresh":
    case "r":
      console.log(chalk.gray("  Refreshing..."));
      printSessions();
      printPendingQuestions();
      break;

    case "help":
    case "h":
      console.log(chalk.bold("\n  Commands:"));
      console.log(`  ${chalk.cyan("q<N> <answer>")}  Answer question N`);
      console.log(`  ${chalk.cyan("skip q<N>")}      Skip question N`);
      console.log(`  ${chalk.cyan("tell <id> <m>")} Send message to session`);
      console.log(`  ${chalk.cyan("status")}        Show sessions & questions`);
      console.log(`  ${chalk.cyan("refresh")}       Refresh session list`);
      console.log(`  ${chalk.cyan("quit")}          Exit`);
      console.log();
      break;

    case "quit":
    case "exit":
    case "q":
      orchestrator.stop();
      process.exit(0);

    default: {
      // Check if answering a question (e.g., "q1 use cookies")
      if (/^q\d+$/.test(command)) {
        const answer = parts.slice(1).join(" ");
        if (!answer) {
          console.log(chalk.red(`  Usage: ${command} <answer>`));
          break;
        }
        const pending = pendingQuestions.get(command);
        if (!pending) {
          console.log(chalk.red(`  Question ${command} not found. Type 'status' to see questions.`));
          break;
        }
        const success = await orchestrator.answerQuestion(
          pending.session.instanceId,
          pending.question.id,
          answer
        );
        if (success) {
          pendingQuestions.delete(command);
          console.log(chalk.green("  Answer sent."));
        } else {
          console.log(chalk.red("  Failed to send answer."));
        }
        break;
      }

      console.log(chalk.red(`  Unknown: ${command}. Type 'help' for commands.`));
    }
  }
}

async function main(): Promise<void> {
  const { filter, help } = parseArgs();

  if (help) {
    printHelp();
    process.exit(0);
  }

  // Check for API key
  if (!process.env.MORPH_API_KEY) {
    console.error(chalk.red("\n  Error: MORPH_API_KEY environment variable is required."));
    console.log(chalk.gray("  Set it with: export MORPH_API_KEY=your_key\n"));
    process.exit(1);
  }

  printHeader(filter);

  // Create orchestrator with filter
  orchestrator = new SessionOrchestrator({
    pollIntervalMs: 3000,
    autoAnswerEnabled: false, // Surface all questions for MVP
    filter: Object.keys(filter).length > 0 ? filter : undefined,
  });

  // Set up event listeners
  orchestrator.on("sessionDiscovered", (session: MorphSession) => {
    const taskId = session.metadata.taskRunId?.slice(0, 10) ?? "";
    console.log(chalk.green(`\n  + Session: ${session.instanceId} ${taskId ? `(${taskId})` : ""}`));
  });

  orchestrator.on("sessionLost", (instanceId: string) => {
    console.log(chalk.red(`\n  - Session lost: ${instanceId}`));
  });

  orchestrator.on("questionSurfaced", (instanceId: string, question: Question) => {
    questionCounter++;
    const key = `q${questionCounter}`;
    const session = orchestrator.getSessions().find((s) => s.instanceId === instanceId);
    if (session) {
      pendingQuestions.set(key, { session, question });
    }

    const taskId = session?.metadata.taskRunId?.slice(0, 10) ?? instanceId.slice(0, 12);
    console.log(chalk.yellow(`\n  [${key}] Question from ${taskId}:`));
    console.log(chalk.white(`      "${question.question}"`));
    if (question.claudeSuggestion) {
      console.log(chalk.blue(`      Suggestion: ${question.claudeSuggestion}`));
    }
    console.log(chalk.gray(`      Reply: ${key} <your answer>`));
  });

  // Start monitoring
  console.log(chalk.cyan("  Starting session monitor..."));
  orchestrator.start();

  // Wait for initial poll
  await new Promise((resolve) => setTimeout(resolve, 2000));

  // Show initial state
  printSessions();
  printPendingQuestions();

  // Interactive prompt
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const prompt = (): void => {
    rl.question(chalk.cyan("  > "), async (input) => {
      try {
        await handleCommand(input);
      } catch (error) {
        console.error(chalk.red("  Error:"), error);
      }
      prompt();
    });
  };

  rl.on("close", () => {
    console.log(chalk.gray("\n  Goodbye!"));
    orchestrator.stop();
    process.exit(0);
  });

  prompt();
}

main().catch((error) => {
  console.error(chalk.red("Fatal error:"), error);
  process.exit(1);
});
